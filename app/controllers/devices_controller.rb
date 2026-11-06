class DevicesController < ApplicationController
  TELEMETRY = %w[agentVersion appVersion batteryLevel isCharging isDeviceOwner lockTaskState model manufacturer].freeze

  def index
    devices = Device.order(:device_id).map(&:api_json)
    success(devices: devices, kiosks: devices)
  end

  def show
    success(find_device.api_json)
  end

  def register
    device = Device.find_or_initialize_by(device_id: required_id)
    Device.transaction do
      device.lock! if device.persisted?
      device.name ||= params[:deviceName].presence || params[:name].presence || device.device_id
      %w[location os].each { |key| device[key] = params[key] if params.key?(key) }
      apply_telemetry(device)
      # A returning agent must receive the configured URL, not replace it with a stale local URL.
      device.url = reported_url if device.new_record? && reported_url.present?
      device.save!
    end
    success(deviceId: device.device_id, registered: true, targetUrl: device.url, kioskUrl: device.url)
  end

  def heartbeat
    device = Device.find_by!(device_id: required_id)
    Device.transaction do
      device.lock!
      device.name ||= device.device_id
      device.url = reported_url if device.new_record? && reported_url.present?
      apply_telemetry(device)
      device.current_url = params[:currentUrl] if params[:currentUrl].is_a?(String)
      device.reported_maintenance_mode = params[:reportedMaintenanceMode] if [true, false].include?(params[:reportedMaintenanceMode])
      if params[:appliedConfigVersion].is_a?(Integer) && params[:appliedConfigVersion].between?(0, device.config_version)
        device.applied_config_version = params[:appliedConfigVersion]
      end
      if params.key?(:webHealth)
        health = params[:webHealth]
        raise ArgumentError, "webHealth must be an object" unless health.is_a?(ActionController::Parameters)
        allowed = health.permit(:sessionId, :state, :loadedUrl, :lastLoadedAt, :loadDurationMs, :firstContentfulPaintMs, :rendererCrashCount, :error).to_h
        raise ArgumentError, "Invalid web health state" unless %w[loading loaded ready error renderer_crashed].include?(allowed["state"])
        %w[loadDurationMs firstContentfulPaintMs rendererCrashCount].each do |key|
          value = allowed[key]
          raise ArgumentError, "Invalid web health metric" unless value.nil? || (value.is_a?(Numeric) && value.finite? && value >= 0 && value <= 1_000_000_000)
        end
        %w[loadedUrl error lastLoadedAt sessionId].each do |key|
          raise ArgumentError, "Invalid web health text" unless allowed[key].nil? || (allowed[key].is_a?(String) && allowed[key].bytesize <= 2048)
        end
        device.web_health = allowed
      end
      if params.key?(:journalPersistencePending)
        raise ArgumentError, "journalPersistencePending must be boolean" unless [true, false].include?(params[:journalPersistencePending])
        device.journal_persistence_pending = params[:journalPersistencePending]
      end
      device.last_seen = Time.current
      device.save!
    end
    success(deviceId: device.device_id, maintenanceMode: device.maintenance_mode,
      serverTime: Time.current, targetUrl: device.url, kioskUrl: device.url,
      configVersion: device.config_version, maintenanceMessage: device.maintenance_message)
  end

  def configuration
    data = find_device.api_json
    success(data.merge("deviceName" => data["name"]))
  end

  def update
    device = find_device
    device.with_lock do
      %w[name location os model manufacturer].each do |key|
        device[key] = params[key].to_s.strip if params.key?(key)
      end
      if params.key?(:newDeviceId) && device.credential_digest.present? && params[:newDeviceId].to_s.strip.upcase != device.device_id
        raise ArgumentError, "An enrolled device ID cannot change; register and enroll the new identity instead"
      end
      device.device_id = params[:newDeviceId] if params.key?(:newDeviceId)
      device.save!
    end
    success(device.api_json)
  end

  def destroy
    device = find_device
    device.with_lock { device.destroy! }
    success
  end

  def maintenance
    enabled = params[:enabled]
    raise ArgumentError, "enabled boolean field is required" unless [true, false].include?(enabled)
    device = find_device
    device.with_lock do
      next if device.maintenance_mode == enabled && device.maintenance_message == (enabled ? params[:message] : nil)
      device.update!(maintenance_mode: enabled, maintenance_message: enabled ? params[:message] : nil, config_version: device.config_version + 1)
      device.device_commands.create!(command_type: "set_maintenance", payload: { enabled: enabled, message: params[:message], configVersion: device.config_version })
    end
    success(deviceId: device.device_id, maintenanceMode: enabled, message: device.maintenance_message)
  end

  def url
    value = reported_url
    raise ArgumentError, "targetUrl, kioskUrl or url string field is required" unless value.is_a?(String) && value.present?
    device = find_device
    device.with_lock do
      next if device.url == value.strip
      device.update!(url: value.strip, config_version: device.config_version + 1)
      device.device_commands.create!(command_type: "set_url", payload: { targetUrl: device.url, url: device.url, kioskUrl: device.url, configVersion: device.config_version })
    end
    success(deviceId: device.device_id, targetUrl: device.url, kioskUrl: device.url, url: device.url)
  end

  private

  def reported_url
    params[:targetUrl].presence || params[:kioskUrl].presence || params[:url].presence || params[:currentUrl].presence
  end

  def apply_telemetry(device)
    TELEMETRY.each { |key| device[key.underscore] = params[key] if params.key?(key) }
  end
end
