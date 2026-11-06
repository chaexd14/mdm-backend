require 'open3'
require 'digest'
require 'fileutils'
class ApkArtifact
  MAX_BYTES = 300 * 1024 * 1024
  PACKAGE = 'com.saikotech.mdm'
  def self.root
    Pathname.new(ENV.fetch('MDM_RELEASE_STORAGE_ROOT', Rails.root.join('storage', 'private_releases').to_s)).expand_path
  end
  def self.path(key)
    raise ArgumentError, 'Invalid artifact key' unless key.match?(/\A[0-9a-f-]{36}\.apk\z/)
    root.join(key)
  end
  def self.tool(name)
    explicit = ENV["MDM_#{name.upcase}_PATH"]
    return explicit if explicit.present?
    sdk = ENV['ANDROID_HOME'].presence || ENV['ANDROID_SDK_ROOT'].presence
    raise ArgumentError, "Configure MDM_#{name.upcase}_PATH or ANDROID_HOME on the API host" unless sdk
    suffix = Gem.win_platform? ? (name == 'apksigner' ? '.bat' : '.exe') : ''
    candidates = Dir[File.join(sdk, 'build-tools', '*', name + suffix)]
    candidates.max_by { |value| Gem::Version.new(File.basename(File.dirname(value))) } || raise(ArgumentError, 'Android APK verification tools not found')
  end
  def self.run(*args)
    output = nil
    Open3.popen3(*args) do |input, stdout, stderr, wait|
      input.close
      readers = [stdout, stderr].map { |stream| Thread.new { stream.read(65537) || '' } }
      unless wait.join(45)
        Process.kill('KILL', wait.pid) rescue nil
        wait.join
        raise ArgumentError, 'APK verification timed out'
      end
      output = readers.map(&:value)
      raise ArgumentError, 'APK metadata is too large' if output.any? { |value| value.bytesize > 65536 }
      raise ArgumentError, 'APK signature or metadata verification failed' unless wait.value.success?
    end
    output.join("\n")
  end
  def self.inspect_apk(file)
    raise ArgumentError, 'Only a single signed APK is supported' unless File.binread(file, 4) == "PK\x03\x04".b
    signing = run(tool('apksigner'), 'verify', '--print-certs', file.to_s)
    badging = run(tool('aapt2'), 'dump', 'badging', file.to_s)
    package_line = badging.lines.find { |line| line.start_with?('package:') }.to_s
    package = package_line[/name='([^']+)'/, 1]
    raise ArgumentError, 'Wrong package or split APK; upload a universal SaikoTech APK' unless package == PACKAGE && !package_line.include?("split=")
    signers = signing.scan(/Signer #\d+ certificate SHA-256 digest:\s*([a-fA-F0-9:]+)/).flatten.map { |value| value.delete(':').downcase }.uniq
    raise ArgumentError, 'A single verified signing identity is required' unless signers.length == 1 && signers.first.match?(/\A[0-9a-f]{64}\z/)
    code = package_line[/versionCode='(\d+)'/, 1].to_i
    minimum = badging[/^(?:minSdkVersion|sdkVersion):'(\d+)'/, 1].to_i
    raise ArgumentError, 'Invalid APK version or SDK metadata' unless code.positive? && minimum.positive?
    { package_name: package, version_code: code, version_name: package_line[/versionName='([^']*)'/, 1].presence || code.to_s,
      min_sdk: minimum, abis: badging.lines.find { |line| line.start_with?('native-code:') }.to_s.scan(/'([^']+)'/).flatten,
      signer_sha256: signers.first, debug_build: badging.include?('application-debuggable') || signing.match?(/certificate DN:.*CN=Android Debug/i) }
  end
  def self.import(upload, notes:, require_app_ready:)
    raise ArgumentError, 'APK upload is required' unless upload.respond_to?(:tempfile)
    raise ArgumentError, 'APK exceeds the 300 MB limit' if upload.tempfile.size > MAX_BYTES || upload.tempfile.size.zero?
    key = "#{SecureRandom.uuid}.apk"
    FileUtils.mkdir_p(root)
    destination = path(key)
    begin
      FileUtils.cp(upload.tempfile.path, destination)
      metadata = inspect_apk(destination)
      release = AppRelease.create!(metadata.merge(storage_key: key, byte_size: destination.size,
        sha256: Digest::SHA256.file(destination).hexdigest, notes: notes, require_app_ready: require_app_ready))
      release
    rescue Exception
      FileUtils.rm_f(destination)
      raise
    end
  end
end
