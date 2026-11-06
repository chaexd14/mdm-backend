class CommandsController < ApplicationController
  def summary
    success(pendingCount: DeviceCommand.where(status: DeviceCommand::ACTIVE).where("expires_at > ?", Time.current).count)
  end

  def index
    scope = DeviceCommand.includes(:device)
    scope = scope.joins(:device).where(devices: { device_id: params[:deviceId].strip.upcase }) if params[:deviceId].present?
    limit = [[params.fetch(:limit, 50).to_i, 1].max, 100].min
    page = [params.fetch(:page, 1).to_i, 1].max
    success(commands: scope.order(created_at: :desc, id: :desc).limit(limit).offset((page - 1) * limit).map(&:api_json),
      totalCount: scope.count, pendingCount: scope.where(status: DeviceCommand::ACTIVE).where("expires_at > ?", Time.current).count, page: page)
  end

  def create
    device = find_device
    type = params.require(:type)
    raise ArgumentError, "type must be a string" unless type.is_a?(String)
    payload = params[:payload] || {}
    raise ArgumentError, "payload must be an object" unless payload.is_a?(ActionController::Parameters) || payload.is_a?(Hash)
    payload = payload.to_unsafe_h if payload.respond_to?(:to_unsafe_h)
    key = request.headers["Idempotency-Key"].presence
    device.with_lock do
      command = key && device.device_commands.find_by(idempotency_key: key)
      if command && (command.command_type != type.strip || command.payload != payload)
        return render json: { success: false, error: "Idempotency key already used for a different command" }, status: :conflict
      end
      command ||= device.device_commands.create!(command_type: type.strip, payload: payload, idempotency_key: key)
      success(commandId: command.id, deviceId: device.device_id, type: command.command_type, status: command.status)
    end
  end

  def pending
    device = find_device
    wait = [[params.fetch(:wait, 0).to_i, 0].max, 25].min
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    subscription = CommandSignal.subscribe(device.id)
    ActiveRecord::Base.connection_handler.clear_active_connections!
    loop do
      version = subscription.version
      commands = ActiveRecord::Base.connection_pool.with_connection do
        DeviceCommand.transaction do
          expired = device.device_commands.where(status: DeviceCommand::ACTIVE).where("expires_at <= ?", Time.current)
            .where("status = 'pending' OR lease_until <= ?", Time.current).lock
          expired.each { |command| command.update!(status: "expired", error: "Command expired") }
          available = device.device_commands.where(status: DeviceCommand::ACTIVE).where("expires_at > ?", Time.current)
            .where("lease_until IS NULL OR lease_until <= ?", Time.current).order(:created_at, :id).limit(10).lock("FOR UPDATE SKIP LOCKED")
          available.map do |command|
            command.update!(lease_until: 2.minutes.from_now, delivery_attempts: command.delivery_attempts + 1)
            command.api_json
          end
        end
      end
      return success(commands: commands) if commands.any? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      subscription.wait(version, [remaining, 5].min) if remaining.positive?
    end
  ensure
    CommandSignal.unsubscribe(device.id, subscription) if subscription
  end

  def ack
    device = find_device
    status = params.require(:status)
    raise ArgumentError, "status must be received, executed or failed" unless %w[received executed failed].include?(status)
    command = device.device_commands.find(params[:command_id])
    command.with_lock do
      if command.status == status
        return success(status: command.status)
      end
      if DeviceCommand::TERMINAL.include?(command.status)
        return render json: { success: false, error: "Command already terminal", data: { status: command.status } }, status: :conflict
      end
      if status == "received" && command.expires_at <= Time.current
        command.update!(status: "expired", error: "Command expired")
        return render json: { success: false, error: "Command expired" }, status: :conflict
      end
      command.update!(status: status, received_at: command.received_at || Time.current,
        executed_at: status == "received" ? nil : Time.current,
        lease_until: status == "received" ? 2.minutes.from_now : nil,
        error: status == "failed" ? params[:error].to_s.first(2000) : nil)
    end
    success(status: command.status)
  end

  def cancel
    command = find_device.device_commands.find(params[:command_id])
    command.with_lock do
      return render(json: { success: false, error: "Only undelivered commands can be cancelled" }, status: :conflict) unless command.status == "pending" && command.lease_until.nil?
      command.update!(status: "cancelled")
    end
    success
  end
end
