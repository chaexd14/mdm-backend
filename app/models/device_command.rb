class DeviceCommand < ApplicationRecord
  TYPES = %w[check_update reload reload_app refresh restart soft_restart lock_kiosk lock_device lock unlock_kiosk unlock_device unlock set_url update_url change_url set_maintenance maintenance].freeze
  ACTIVE = %w[pending received].freeze
  TERMINAL = %w[executed failed cancelled expired].freeze
  belongs_to :device
  before_validation(on: :create) do
    self.id ||= "cmd_#{SecureRandom.uuid}"
    self.expires_at ||= 24.hours.from_now
  end
  validates :expires_at, presence: true
  validates :command_type, inclusion: { in: TYPES }, on: :create
  validates :status, inclusion: { in: ACTIVE + TERMINAL }
  validates :payload, exclusion: { in: [nil] }
  validates :idempotency_key, length: { maximum: 128 }, allow_nil: true
  validate :valid_payload, on: :create
  after_create { DashboardEvent.publish("command_created", command: api_json); CommandSignal.publish(device_id) }
  after_update { DashboardEvent.publish("command_updated", command: api_json) }

  def valid_payload
    unless payload.is_a?(Hash)
      errors.add(:payload, "must be an object")
      return
    end
    if %w[set_url update_url change_url].include?(command_type)
      value = payload["targetUrl"] || payload["url"] || payload["kioskUrl"]
      errors.add(:payload, "requires an HTTP(S) URL") unless value.is_a?(String) && value.match?(%r{\Ahttps?://[^\s/]+(?:/[^\s]*)?\z}i)
    end
    if %w[set_maintenance maintenance].include?(command_type) && ![true, false].include?(payload["enabled"])
      errors.add(:payload, "requires boolean enabled")
    end
  end

  def api_json
    { id: id, deviceId: device.device_id, kioskId: device_id.to_s, type: command_type,
      payload: payload, status: status, createdAt: created_at, executedAt: executed_at,
      expiresAt: expires_at, receivedAt: received_at, deliveryAttempts: delivery_attempts, error: error }.as_json
  end
end
