class DeviceUpdate < ApplicationRecord
  belongs_to :device
  belongs_to :app_release
  has_many :update_attempts, dependent: :destroy
  before_validation(on: :create) { self.id ||= SecureRandom.uuid }
  validates :policy, inclusion: { in: %w[approval automatic] }
  validates :desired_state, inclusion: { in: %w[active completed cancelled] }
  def attempt
    if update_attempts.loaded?
      update_attempts.detect { |item| item.attempt_number == attempt_number } || raise(ActiveRecord::RecordNotFound)
    else
      update_attempts.find_by!(attempt_number: attempt_number)
    end
  end
  def api_json
    { id: id, deviceId: device.device_id, policy: policy, desiredState: desired_state, attemptNumber: attempt_number,
      notBefore: not_before, windowEnd: window_end, release: app_release.api_json, attempt: attempt.api_json, createdAt: created_at }.as_json
  end
  def publish_change
    DashboardEvent.publish('update_progress', update: api_json)
  end
  def allowed_now?
    desired_state == 'active' && app_release.state == 'published' &&
      (policy != 'automatic' || (not_before && window_end && Time.current.between?(not_before, window_end)))
  end
end
