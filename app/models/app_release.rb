class AppRelease < ApplicationRecord
  has_many :device_updates, dependent: :restrict_with_exception
  before_validation(on: :create) { self.id ||= SecureRandom.uuid }
  validates :state, inclusion: { in: %w[draft published paused revoked] }
  validates :package_name, inclusion: { in: [ApkArtifact::PACKAGE] }, on: :create
  validates :version_code, numericality: { only_integer: true, greater_than: 0 }
  validates :version_name, length: { in: 1..80 }
  validates :sha256, :signer_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :notes, length: { maximum: 5000 }
  attr_readonly :package_name, :version_code, :version_name, :min_sdk, :abis, :sha256, :signer_sha256, :storage_key, :byte_size, :debug_build, :require_app_ready
  after_save { DashboardEvent.publish('release_updated', release: api_json) }
  def api_json
    { id: id, packageName: package_name, versionCode: version_code, versionName: version_name, minSdk: min_sdk, abis: abis,
      sha256: sha256, signerSha256: signer_sha256, byteSize: byte_size, debugBuild: debug_build, requireAppReady: require_app_ready,
      notes: notes, state: state, createdAt: created_at }.as_json
  end
  def publish!
    raise ArgumentError, 'This release belongs to a different Android package; upload a current MDM APK' unless package_name == ApkArtifact::PACKAGE
    allowed = ENV.fetch('MDM_RELEASE_SIGNER_SHA256', '').split(',').map { |value| value.delete(':').strip.downcase }
    raise ArgumentError, 'Configure the trusted MDM_RELEASE_SIGNER_SHA256 before publishing' unless allowed.include?(signer_sha256)
    raise ArgumentError, 'Debug APKs cannot be published in production' if Rails.env.production? && debug_build
    raise ArgumentError, 'A revoked release cannot be republished' if state == 'revoked'
    raise ArgumentError, 'APK artifact is missing or modified' unless ApkArtifact.path(storage_key).file? && Digest::SHA256.file(ApkArtifact.path(storage_key)).hexdigest == sha256
    update!(state: 'published')
  end
end
