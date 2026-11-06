class DashboardEvent < ApplicationRecord
  def self.publish(type, data)
    event = create!(event_type: type, payload: data.merge(type: type), created_at: Time.current)
    CommandSignal.publish("dashboard")
    event
  end
end
