class AppReleasesController < ApplicationController
  def index
    success(releases: AppRelease.order(created_at: :desc).limit(100).map(&:api_json),
      updates: DeviceUpdate.includes(:device, :app_release, :update_attempts).order(created_at: :desc).limit(200).map(&:api_json))
  end
  def create
    release = ApkArtifact.import(params[:apk], notes: params[:notes].to_s, require_app_ready: params[:requireAppReady].to_s == 'true')
    success(release.api_json)
  end
  def change
    release = AppRelease.find(params[:id])
    release.with_lock do
      case params.require(:state)
      when 'published' then release.publish!
      when 'paused', 'revoked'
        raise ArgumentError, 'A revoked release is immutable' if release.state == 'revoked'
        release.update!(state: params[:state])
      else raise ArgumentError, 'Invalid release state'
      end
    end
    success(release.api_json)
  end
  def assign
    release = AppRelease.find(params[:id])
    ids = params.require(:deviceIds)
    raise ArgumentError, 'Select between 1 and 500 device IDs' unless ids.is_a?(Array) && ids.length.between?(1, 500) && ids.all? { |id| id.is_a?(String) }
    ids = ids.map { |id| id.strip.upcase }.uniq.sort
    policy = params.fetch(:policy, 'approval')
    raise ArgumentError, 'Invalid update policy' unless %w[approval automatic].include?(policy)
    start_at = params[:notBefore].present? ? Time.iso8601(params[:notBefore]) : nil
    end_at = params[:windowEnd].present? ? Time.iso8601(params[:windowEnd]) : nil
    if policy == 'automatic'
      raise ArgumentError, 'Automatic installs require a valid maintenance window of at most 24 hours' unless start_at && end_at && end_at > start_at && end_at > Time.current && end_at - start_at <= 24.hours
    end
    created = []
    DeviceUpdate.transaction do
      release.lock!
      raise ArgumentError, 'Only a published release can be assigned' unless release.state == 'published'
      devices = Device.where(device_id: ids).order(:id).lock.to_a
      raise ArgumentError, 'One or more device IDs do not exist' unless devices.length == ids.length
      devices.each do |device|
        raise ArgumentError, "#{device.device_id} already has an active update" if device.device_updates.where(desired_state: 'active').exists?
        raise ArgumentError, "#{device.device_id} is not reported as Device Owner" if policy == 'automatic' && device.is_device_owner != true
        update = device.device_updates.create!(app_release: release, policy: policy, not_before: start_at, window_end: end_at)
        update.update_attempts.create!(attempt_number: 1)
        device.device_commands.create!(command_type: 'check_update', payload: { assignmentId: update.id })
        update.publish_change
        created << update.id
      end
    end
    success(assignmentIds: created)
  end
  def control
    update = DeviceUpdate.find(params[:id])
    update.device.with_lock do
      update.lock!
      attempt = update.attempt
      case params.require(:actionType)
      when 'cancel'
        raise ArgumentError, 'Installation has started and cannot be recalled' if UpdateAttempt::COMMITTED.include?(attempt.state)
        update.update!(desired_state: 'cancelled')
        attempt.update!(state: 'cancelled')
      when 'retry'
        raise ArgumentError, 'Only failed or cancelled attempts can be retried' unless %w[failed cancelled superseded].include?(attempt.state)
        raise ArgumentError, 'Publish the release before retrying' unless update.app_release.state == 'published'
        raise ArgumentError, 'Another update is active for this device' if update.device.device_updates.where(desired_state: 'active').where.not(id: update.id).exists?
        raise ArgumentError, 'Assign a new maintenance window instead of retrying an expired automatic update' if update.policy == 'automatic' && update.window_end <= Time.current
        update.update!(attempt_number: update.attempt_number + 1, desired_state: 'active')
        update.update_attempts.create!(attempt_number: update.attempt_number)
      else raise ArgumentError, 'Invalid update action'
      end
      update.device.device_commands.create!(command_type: 'check_update', payload: { assignmentId: update.id })
      update.publish_change
    end
    success(update.api_json)
  end
end
