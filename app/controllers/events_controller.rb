class EventsController < ApplicationController
  include ActionController::Live

  def index
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache, no-transform"
    response.headers["X-Accel-Buffering"] = "no"
    subscription = CommandSignal.subscribe("dashboard")
    cursor = request.headers["Last-Event-ID"].presence&.to_i || DashboardEvent.maximum(:id) || 0
    ActiveRecord::Base.connection_handler.clear_active_connections!
    response.stream.write("event: connected\ndata: #{ { time: Time.current }.to_json }\n\n")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      version = subscription.version
      events = ActiveRecord::Base.connection_pool.with_connection do
        DashboardEvent.where("id > ?", cursor).order(:id).limit(100).to_a
      end
      events.each do |event|
        response.stream.write("id: #{event.id}\nevent: #{event.event_type}\ndata: #{event.payload.to_json}\n\n")
        cursor = event.id
      end
      response.stream.write(": ping\n\n") if events.empty?
      next if events.length == 100
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      subscription.wait(version, [remaining, 5].min) if remaining.positive?
    end
  rescue IOError, ActionController::Live::ClientDisconnected
    # EventSource reconnects using Last-Event-ID after a normal close or disconnect.
  ensure
    CommandSignal.unsubscribe("dashboard", subscription) if subscription
    response.stream.close
  end
end
