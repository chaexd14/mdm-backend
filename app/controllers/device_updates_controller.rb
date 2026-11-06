class DeviceUpdatesController < ApplicationController
  def current
    updates = find_device.device_updates
    update = updates.where(desired_state: 'active').order(created_at: :desc).first || updates.order(created_at: :desc).first
    success(assignment: update&.api_json, serverTime: Time.current)
  end
  def report
    update = scoped_update
    update.with_lock do
      attempt = update.attempt
      raise ArgumentError, 'Stale update attempt' unless params[:attemptNumber] == update.attempt_number
      sequence = params.require(:sequence)
      raise ArgumentError, 'Invalid report sequence' unless sequence.is_a?(Integer) && sequence.positive? && sequence <= 9_000_000_000_000_000
      return success(accepted: false, state: attempt.state) if sequence <= attempt.sequence || update.desired_state == 'cancelled'
      state = params.require(:state)
      raise ArgumentError, 'Invalid update state' unless UpdateAttempt::STATES.include?(state)
      return success(accepted: false, state: attempt.state) if UpdateAttempt::TERMINAL.include?(attempt.state)
      if %w[installed confirmed].include?(state)
        release = update.app_release
        raise ArgumentError, 'Installed artifact does not match the assigned release' unless params[:installedVersionCode] == release.version_code && params[:installedSha256] == release.sha256 && params[:installedSignerSha256] == release.signer_sha256
        raise ArgumentError, 'Report installed before confirming health' if state == 'confirmed' && (!attempt.installed_at || attempt.installed_at > 30.seconds.ago)
      end
      raise ArgumentError, 'Installation must be authorized through the permit endpoint' if %w[installing awaiting_system_approval].include?(state) && !UpdateAttempt::COMMITTED.include?(attempt.state)
      if UpdateAttempt::COMMITTED.include?(attempt.state) && %w[assigned downloading verified awaiting_approval scheduled paused cancelled superseded].include?(state)
        raise ArgumentError, 'Installation state cannot regress'
      end
      progress = params.fetch(:progress, attempt.progress)
      bytes = params.fetch(:bytesDownloaded, attempt.bytes_downloaded)
      raise ArgumentError, 'Invalid download progress' unless progress.is_a?(Integer) && progress.between?(0, 100) && bytes.is_a?(Integer) && bytes.between?(0, update.app_release.byte_size)
      attempt.update!(sequence: sequence, state: state, progress: progress, bytes_downloaded: bytes,
        error_code: params[:errorCode].to_s.first(80).presence, error_message: params[:errorMessage].to_s.first(1000).presence,
        installed_version_code: params[:installedVersionCode], installed_at: attempt.installed_at || (state == 'installed' ? Time.current : nil),
        confirmed_at: state == 'confirmed' ? Time.current : nil, last_reported_at: Time.current)
      update.update!(desired_state: 'completed') if UpdateAttempt::TERMINAL.include?(state)
      update.publish_change
    end
    success(accepted: true)
  end
  def permit
    update = scoped_update
    update.with_lock do
      raise ArgumentError, 'Stale update attempt' unless params[:attemptNumber] == update.attempt_number
      raise ArgumentError, 'Release paused, revoked, cancelled, or outside its maintenance window' unless update.allowed_now?
      attempt = update.attempt
      raise ArgumentError, 'This attempt cannot install' if UpdateAttempt::TERMINAL.include?(attempt.state) || attempt.state == 'installed'
      session = params.require(:installerSessionId)
      raise ArgumentError, 'Invalid installer session' unless session.is_a?(Integer) && session >= 0
      raise ArgumentError, 'A different installation session is already active' if attempt.installer_session_id && attempt.installer_session_id != session
      attempt.update!(state: 'installing', installer_session_id: session, last_reported_at: Time.current)
      update.publish_change
    end
    success(mayInstall: true, serverTime: Time.current)
  end
  def artifact
    update = scoped_update
    raise ArgumentError, 'Artifact is not available for this assignment' unless update.desired_state == 'active' && update.app_release.state == 'published'
    release = update.app_release
    file = ApkArtifact.path(release.storage_key)
    raise ActiveRecord::RecordNotFound unless file.file?
    size = file.size
    start = 0
    range = request.headers['Range']
    if range.present? && (request.headers['If-Range'].blank? || request.headers['If-Range'].delete('"') == release.sha256)
      unless range.match?(/\Abytes=\d+-\z/)
        response.headers['Content-Range'] = "bytes */#{size}"
        return head :range_not_satisfiable
      end
      start = range[/\d+/].to_i
      if start >= size
        response.headers['Content-Range'] = "bytes */#{size}"
        return head :range_not_satisfiable
      end
      response.status = 206
      response.headers['Content-Range'] = "bytes #{start}-#{size - 1}/#{size}"
    end
    response.headers['Accept-Ranges'] = 'bytes'
    response.headers['ETag'] = %Q("#{release.sha256}")
    response.headers['Content-Type'] = 'application/vnd.android.package-archive'
    response.headers['Content-Disposition'] = "attachment; filename=saikotech-#{release.version_code}.apk"
    response.headers['Content-Length'] = (size - start).to_s
    ActiveRecord::Base.connection_handler.clear_active_connections!
    self.response_body = Enumerator.new do |stream|
      File.open(file, 'rb') do |input|
        input.seek(start)
        while (chunk = input.read(65536))
          stream << chunk
        end
      end
    end
  end
  private
  def scoped_update
    find_device.device_updates.includes(:app_release).find(params[:id])
  end
end
