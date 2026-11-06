require 'test_helper'
require 'tmpdir'
require 'minitest/mock'

class AppUpdatesTest < ActionDispatch::IntegrationTest
  setup do
    @environment = ENV.to_h.slice('MDM_RELEASE_STORAGE_ROOT', 'MDM_RELEASE_SIGNER_SHA256', 'MDM_AUTH_REQUIRED', 'MDM_ADMIN_TOKEN')
    @directory = Dir.mktmpdir('mdm-updater-test')
    ENV['MDM_RELEASE_STORAGE_ROOT'] = @directory
    ENV['MDM_RELEASE_SIGNER_SHA256'] = 'a' * 64
    ENV['MDM_AUTH_REQUIRED'] = 'true'
    ENV['MDM_ADMIN_TOKEN'] = 'updater-test-administrator-token-32-characters'
    @admin = { 'Authorization' => "Bearer #{ENV['MDM_ADMIN_TOKEN']}" }
    @device = Device.create!(device_id: 'UPDATE-001', name: 'Pilot', is_device_owner: true, credential_digest: Digest::SHA256.hexdigest('device-secret'))
    @agent = { 'Authorization' => 'Bearer device-secret' }
    @key = "#{SecureRandom.uuid}.apk"
    File.binwrite(ApkArtifact.path(@key), 'signed-apk-test-content')
    @release = AppRelease.create!(package_name: ApkArtifact::PACKAGE, version_code: 42, version_name: '1.4.2', min_sdk: 24,
      abis: [], signer_sha256: 'a' * 64, sha256: Digest::SHA256.file(ApkArtifact.path(@key)).hexdigest,
      byte_size: ApkArtifact.path(@key).size, storage_key: @key)
  end
  teardown do
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
    %w[MDM_RELEASE_STORAGE_ROOT MDM_RELEASE_SIGNER_SHA256 MDM_AUTH_REQUIRED MDM_ADMIN_TOKEN].each { |key| ENV[key] = @environment[key] }
  end
  def assign(policy: 'approval', **extra)
    @release.publish!
    post "/api/app-releases/#{@release.id}/assign", params: { deviceIds: [@device.device_id], policy: policy }.merge(extra), headers: @admin, as: :json
    assert_response :success
    @update = @device.device_updates.last
    @path = "/api/devices/#{@device.device_id}/updates/#{@update.id}"
  end
  def report(sequence, state, **extra)
    post "#{@path}/report", params: { attemptNumber: @update.attempt_number, sequence: sequence, state: state, progress: 50, bytesDownloaded: 10 }.merge(extra), headers: @agent, as: :json
  end
  def permit(session = 123)
    post "#{@path}/permit", params: { attemptNumber: @update.attempt_number, installerSessionId: session }, headers: @agent, as: :json
  end
  test 'publishing rejects untrusted certificates and modified artifacts' do
    ENV['MDM_RELEASE_SIGNER_SHA256'] = 'b' * 64
    assert_raises(ArgumentError) { @release.publish! }
    ENV['MDM_RELEASE_SIGNER_SHA256'] = 'a' * 64
    File.binwrite(ApkArtifact.path(@key), 'modified')
    assert_raises(ArgumentError) { @release.publish! }
    assert_equal 'draft', @release.reload.state
  end
  test 'APK tool output handles empty stderr and rejects failing commands' do
    assert_includes ApkArtifact.run(RbConfig.ruby, '-e', 'STDOUT.write("verified")'), 'verified'
    assert_raises(ArgumentError) { ApkArtifact.run(RbConfig.ruby, '-e', 'exit 1') }
  end
  test 'APK metadata accepts current and legacy SDK badging fields' do
    apk = File.join(@directory, 'metadata.apk')
    File.binwrite(apk, "PK\x03\x04")
    %w[minSdkVersion sdkVersion].each do |field|
      signing = "Signer #1 certificate SHA-256 digest: #{'a' * 64}"
      badging = "package: name='com.saikotech.mdm' versionCode='42' versionName='1.4.2'\n#{field}:'24'\nnative-code: 'arm64-v8a'\n"
      ApkArtifact.stub(:tool, ->(name) { name }) do
        ApkArtifact.stub(:run, ->(*args) { args.first == 'apksigner' ? signing : badging }) do
          metadata = ApkArtifact.inspect_apk(apk)
          assert_equal 24, metadata[:min_sdk]
          assert_equal 42, metadata[:version_code]
          assert_equal ['arm64-v8a'], metadata[:abis]
        end
      end
    end
  end
  test 'device credentials cannot manage releases or impersonate another device' do
    assign
    get '/api/app-releases', headers: @agent
    assert_response :unauthorized
    get "/api/devices/#{@device.device_id}/updates/current", headers: @admin
    assert_response :unauthorized
    get '/api/devices/OTHER/updates/current', headers: @agent
    assert_response :unauthorized
    get "/api/devices/#{@device.device_id}/updates/current", headers: @agent
    assert_response :success
    assert_equal @update.id, response.parsed_body.dig('data', 'assignment', 'id')
    other = Device.create!(device_id: 'UPDATE-002', name: 'Other tablet')
    foreign = other.device_updates.create!(app_release: @release, policy: 'approval')
    foreign.update_attempts.create!(attempt_number: 1)
    get "/api/devices/#{@device.device_id}/updates/#{foreign.id}/apk", headers: @agent
    assert_response :not_found
  end
  test 'progress reports are ordered and duplicate requests are idempotent' do
    assign
    report(2, 'downloading')
    assert_response :success
    report(1, 'assigned')
    assert_equal false, response.parsed_body.dig('data', 'accepted')
    report(2, 'verified')
    assert_equal false, response.parsed_body.dig('data', 'accepted')
    assert_equal 'downloading', @update.attempt.state
    report(3, 'downloading', bytesDownloaded: @release.byte_size + 1)
    assert_response :bad_request
    report(3, 'installing')
    assert_response :bad_request
  end
  test 'permit is idempotent for one session and refuses paused revoked and cancelled updates' do
    assign
    @release.update!(state: 'paused')
    permit
    assert_response :bad_request
    @release.publish!
    permit
    assert_response :success
    permit
    assert_response :success
    permit(124)
    assert_response :bad_request
    post "/api/device-updates/#{@update.id}/control", params: { actionType: 'cancel' }, headers: @admin, as: :json
    assert_response :bad_request
    report(1, 'cancelled')
    assert_response :bad_request
    @release.update!(state: 'revoked')
    permit
    assert_response :bad_request
    assert_raises(ArgumentError) { @release.publish! }
  end
  test 'health confirmation requires matching evidence and a stabilization interval' do
    assign
    report(1, 'confirmed')
    assert_response :bad_request
    evidence = { installedVersionCode: 42, installedSha256: @release.sha256, installedSignerSha256: @release.signer_sha256 }
    report(2, 'installed', **evidence)
    assert_response :success
    report(3, 'confirmed', **evidence)
    assert_response :bad_request
    travel 31.seconds do
      report(4, 'confirmed', **evidence)
      assert_response :success
    end
    assert_equal 'completed', @update.reload.desired_state
    assert_equal 'confirmed', @update.attempt.state
    report(5, 'failed')
    assert_equal false, response.parsed_body.dig('data', 'accepted')
  end
  test 'cancelled attempts cannot install and retries isolate late reports' do
    assign
    post "/api/device-updates/#{@update.id}/control", params: { actionType: 'cancel' }, headers: @admin, as: :json
    assert_response :success
    permit
    assert_response :bad_request
    post "/api/device-updates/#{@update.id}/control", params: { actionType: 'retry' }, headers: @admin, as: :json
    assert_response :success
    report(99, 'verified')
    assert_response :bad_request
    assert_equal 2, @update.reload.attempt_number
    assert_equal 'assigned', @update.attempt.state
  end
  test 'automatic updates require owner eligibility and enforce server maintenance time' do
    assign(policy: 'automatic', notBefore: 1.hour.from_now.iso8601, windowEnd: 2.hours.from_now.iso8601)
    permit
    assert_response :bad_request
    travel 90.minutes do
      permit
      assert_response :success
    end
    travel 3.hours do
      permit
      assert_response :bad_request
    end
  end
  test 'downloads require assigned credentials and support safe byte resume' do
    assign
    get "#{@path}/apk", headers: @agent.merge('Range' => 'bytes=7-', 'If-Range' => %Q("#{@release.sha256}"))
    assert_response :partial_content
    assert_equal 'apk-test-content', response.body
    get "#{@path}/apk", headers: @agent.merge('Range' => 'bytes=9999-')
    assert_response :range_not_satisfiable
    get "#{@path}/apk", headers: @agent.merge('Range' => 'bytes=7-', 'If-Range' => 'old-hash')
    assert_response :success
    assert_equal 'signed-apk-test-content', response.body
    @release.update!(state: 'paused')
    get "#{@path}/apk", headers: @agent
    assert_response :bad_request
  end
  test 'retrying an older assignment takes priority over newer completed history' do
    assign
    @update.update!(desired_state: 'completed')
    @update.attempt.update!(state: 'failed')
    travel 1.minute do
      later = @device.device_updates.create!(app_release: @release, policy: 'approval', desired_state: 'completed')
      later.update_attempts.create!(attempt_number: 1, state: 'failed')
      post "/api/device-updates/#{@update.id}/control", params: { actionType: 'retry' }, headers: @admin, as: :json
      assert_response :success
      get "/api/devices/#{@device.device_id}/updates/current", headers: @agent
      assert_equal @update.id, response.parsed_body.dig('data', 'assignment', 'id')
      assert_equal 2, response.parsed_body.dig('data', 'assignment', 'attemptNumber')
    end
  end
end
