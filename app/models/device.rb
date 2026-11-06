class Device < ApplicationRecord
  has_many :device_updates, dependent: :destroy
  has_many :device_commands, dependent: :destroy
  before_validation { self.device_id = device_id.to_s.strip.upcase }
  validates :device_id, :name, presence: true
  validates :device_id, uniqueness: true
  validates :battery_level, numericality: { only_integer: true, in: 0..100 }, allow_nil: true
  validates :url, format: { with: %r{\Ahttps?://[^\s/]+(?:/[^\s]*)?\z}i }
  after_save :publish_change
  after_destroy { DashboardEvent.publish("device_deleted", deviceId: device_id, id: id.to_s) }

  def api_json
    attributes.except("id", "credential_digest", "enrollment_digest", "enrollment_expires_at", "lock_version").transform_keys { |key| key.camelize(:lower) }.merge(
      "id" => id.to_s, "revision" => lock_version, "url" => url, "targetUrl" => url, "kioskUrl" => url,
      "connectionQuality" => !last_seen || last_seen <= 2.minutes.ago ? "offline" : last_seen <= 1.minute.ago ? "stale" : "healthy",
      "status" => last_seen && last_seen > 2.minutes.ago ? "online" : "offline"
    ).as_json
  end

  private

  def publish_change
    if saved_change_to_device_id? && device_id_before_last_save.present?
      DashboardEvent.publish("device_deleted", deviceId: device_id_before_last_save)
    end
    telemetry_fields = %w[last_seen updated_at lock_version battery_level is_charging is_device_owner lock_task_state agent_version app_version current_url reported_maintenance_mode applied_config_version web_health journal_persistence_pending]
    if !previously_new_record? && (saved_changes.keys - telemetry_fields).empty?
      snapshot = api_json
      fields = saved_changes.keys.map { |key| key.camelize(:lower) } + %w[id createdAt deviceId revision status connectionQuality]
      DashboardEvent.publish("device_telemetry", device: snapshot.slice(*fields))
    else
      DashboardEvent.publish("device_updated", device: api_json)
    end
  end
end
