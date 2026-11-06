require "set"

# One LISTEN connection per worker, never one database connection per idle device.
# The database remains the source of truth; lost notifications only delay the next
# five-second reconciliation. pg_notify is delivered only when its transaction commits.
class CommandSignalConnection < ActiveRecord::Base
  self.abstract_class = true
end

class CommandSignal
  class Subscription
    def initialize
      @mutex, @condition, @version = Mutex.new, ConditionVariable.new, 0
    end
    def version
      @mutex.synchronize { @version }
    end
    def signal
      @mutex.synchronize { @version += 1; @condition.broadcast }
    end
    def wait(version, seconds)
      @mutex.synchronize { @condition.wait(@mutex, seconds) if @version == version }
    end
  end

  @mutex = Mutex.new
  @subscriptions = {}

  class << self
    def subscribe(device_id)
      subscription = Subscription.new
      @mutex.synchronize { (@subscriptions[device_id.to_s] ||= Set.new).add(subscription) }
      start_listener unless Rails.env.test? && ENV["MDM_NOTIFICATION_LISTENER"] != "true"
      subscription
    end

    def unsubscribe(device_id, subscription)
      @mutex.synchronize do
        @subscriptions[device_id.to_s]&.delete(subscription)
        @subscriptions.delete(device_id.to_s) if @subscriptions[device_id.to_s]&.empty?
      end
    end

    def publish(device_id)
      connection = ActiveRecord::Base.connection
      connection.execute("SELECT pg_notify('mdm_commands', #{connection.quote(device_id.to_s)})")
    end

    def start_listener
      @mutex.synchronize do
        return if @thread&.alive?
        @thread = Thread.new do
          Thread.current.name = "mdm-command-notifications"
          loop do
            begin
              config = ActiveRecord::Base.connection_db_config.configuration_hash.merge(pool: 1)
              CommandSignalConnection.establish_connection(config)
              CommandSignalConnection.connection_pool.with_connection do |connection|
                raw = connection.raw_connection
                raw.exec("LISTEN mdm_commands")
                loop do
                  raw.wait_for_notify(5) do |_channel, _pid, device_id|
                    subscribers = @mutex.synchronize { @subscriptions[device_id]&.to_a || [] }
                    subscribers.each(&:signal)
                  end
                end
              end
            rescue StandardError => error
              Rails.logger.warn({ event: "mdm_notification_reconnect", error: error.class.name }.to_json)
              CommandSignalConnection.connection_pool.disconnect!
              sleep 5
            end
          end
        end
      end
    end
  end
end
