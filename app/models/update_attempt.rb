class UpdateAttempt < ApplicationRecord
  STATES = %w[assigned downloading verified awaiting_approval scheduled installing awaiting_system_approval installed confirmed failed cancelled superseded paused].freeze
  TERMINAL = %w[confirmed failed cancelled superseded].freeze
  COMMITTED = %w[installing awaiting_system_approval installed confirmed].freeze
  belongs_to :device_update
  validates :state, inclusion: { in: STATES }
  validates :progress, numericality: { only_integer: true, in: 0..100 }
  def api_json
    { state: state, sequence: sequence, progress: progress, bytesDownloaded: bytes_downloaded,
      installerSessionId: installer_session_id, errorCode: error_code, errorMessage: error_message,
      installedVersionCode: installed_version_code, installedAt: installed_at, confirmedAt: confirmed_at, lastReportedAt: last_reported_at }.as_json
  end
end
