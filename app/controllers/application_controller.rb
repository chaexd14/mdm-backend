require "digest"
class ApplicationController < ActionController::API
  include ActionController::Cookies
  wrap_parameters false
  before_action :authenticate_api!
  after_action :audit_mutation

  def audit_mutation
    return if request.get? || request.options?
    Rails.logger.info({ event: "mdm_mutation", requestId: request.request_id,
      actor: @admin_authenticated ? "administrator" : "device", adminUsername: @current_admin_account&.username, action: "#{controller_name}.#{action_name}",
      deviceId: params[:device_id] || params[:deviceId], commandId: params[:command_id],
      status: response.status }.to_json)
  end
  before_action { response.headers["Cache-Control"] = "no-store" }

  def authenticate_api!
    return if request.options? || (controller_name == "enrollments" && action_name == "redeem")
    if (session = browser_admin_session) && !device_only_action?
      @admin_authenticated = true
      @current_admin_account = session.admin_account
      verify_dashboard_origin! unless request.get? || request.head?
      return
    end
    return unless Rails.env.production? || ENV["MDM_AUTH_REQUIRED"] == "true" || AdminAccount.exists?
    token = request.authorization.to_s[/\ABearer (.+)\z/, 1].to_s
    admin = ENV["MDM_ADMIN_TOKEN"].to_s
    @admin_authenticated = admin.bytesize >= 32 && token.present? &&
      ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(admin), Digest::SHA256.hexdigest(token))
    return if @admin_authenticated && !device_only_action?
    if device_action?
      identity = params[:device_id].presence || params[:deviceId]
      device = Device.find_by(device_id: identity.to_s.strip.upcase)
      if device&.credential_digest.present? && token.present? &&
          ActiveSupport::SecurityUtils.secure_compare(device.credential_digest, Digest::SHA256.hexdigest(token))
        return
      end
    end
    render json: { success: false, error: "Authentication required" }, status: :unauthorized
  end

  def browser_admin_session
    return @browser_admin_session if defined?(@browser_admin_session)
    candidate = AdminSession.from_token(cookies[AdminSession::COOKIE])
    @browser_admin_session = candidate if candidate&.admin_account&.active?
  end

  def session_cookie_options
    mode = ENV.fetch('MDM_SESSION_SAME_SITE', 'lax').downcase
    raise ArgumentError, 'Invalid session cookie SameSite setting' unless %w[lax strict none].include?(mode)
    { httponly: true, secure: Rails.env.production? || request.ssl?, same_site: mode.to_sym, path: '/' }
  end

  def verify_dashboard_origin!
    origins = ENV.fetch('FRONTEND_ORIGINS', 'http://localhost:3000,http://127.0.0.1:3000').split(',').map { |origin| origin.strip.delete_suffix('/') }
    return true if (origins + [request.base_url]).include?(request.headers['Origin'])
    render json: { success: false, error: 'Dashboard request origin is not allowed' }, status: :forbidden
    false
  end

  def device_action?
    return true if controller_name == 'device_updates'
    (controller_name == "devices" && %w[register heartbeat configuration maintenance url].include?(action_name)) ||
      (controller_name == "commands" && %w[pending ack].include?(action_name))
  end

  def device_only_action?
    return true if controller_name == 'device_updates'
    (controller_name == "devices" && action_name == "heartbeat") ||
      (controller_name == "commands" && %w[pending ack].include?(action_name))
  end
  rescue_from ActiveRecord::StaleObjectError do
    render json: { success: false, error: "Device changed concurrently; retry the request" }, status: :conflict
  end
  rescue_from ActiveRecord::RecordNotFound do
    render json: { success: false, error: "Device or command not found" }, status: :not_found
  end
  rescue_from ActiveRecord::RecordInvalid do |error|
    render json: { success: false, error: error.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end
  rescue_from ActiveRecord::RecordNotUnique do
    render json: { success: false, error: "Device ID already exists" }, status: :conflict
  end
  rescue_from ActionController::ParameterMissing, ActionDispatch::Http::Parameters::ParseError, ArgumentError do |error|
    render json: { success: false, error: error.message }, status: :bad_request
  end

  def options
    head :no_content
  end

  private

  def success(data = nil)
    render json: { success: true, data: data }
  end

  def find_device
    Device.find_by!(device_id: params[:device_id].to_s.strip.upcase)
  end

  def required_id
    value = params.require(:deviceId)
    raise ArgumentError, "deviceId must be a string" unless value.is_a?(String)
    value.strip.upcase
  end
end
