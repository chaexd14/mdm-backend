class SessionsController < ApplicationController
  skip_before_action :authenticate_api!
  before_action :verify_dashboard_origin!, only: %i[create destroy]
  LOGIN_STORE = ActiveSupport::Cache::MemoryStore.new(size: 8.megabytes)
  DUMMY_DIGEST = BCrypt::Password.create(SecureRandom.hex(32)).to_s.freeze
  rate_limit to: 15, within: 3.minutes, only: :create, store: LOGIN_STORE,
    with: -> { render json: { success: false, error: 'Too many sign-in attempts. Please try again later.' }, status: :too_many_requests }

  def show
    session = browser_admin_session
    return unauthorized_login unless session
    success(user: session.admin_account.api_json, expiresAt: session.expires_at)
  end

  def create
    username = params[:username].to_s.strip.downcase
    password = params[:password].to_s
    account = username.bytesize <= 80 ? AdminAccount.find_by(username: username) : nil
    unless account
      BCrypt::Password.new(DUMMY_DIGEST).is_password?(password.bytesize <= 72 ? password : '')
      return invalid_credentials
    end
    session = nil
    token = SecureRandom.urlsafe_base64(48)
    account.with_lock do
      if account.locked_until&.future?
        return render json: { success: false, error: 'Too many sign-in attempts. Please try again later.' }, status: :too_many_requests
      end
      if !account.active? || password.bytesize > 72 || !account.authenticate(password)
        attempts = account.locked_until&.past? ? 1 : account.failed_login_attempts + 1
        account.update!(failed_login_attempts: attempts, locked_until: attempts >= 10 ? 15.minutes.from_now : nil)
        return invalid_credentials
      end
      account.update!(failed_login_attempts: 0, locked_until: nil)
      session = account.admin_sessions.create!(token_digest: Digest::SHA256.hexdigest(token), expires_at: 12.hours.from_now)
    end
    browser_admin_session&.destroy!
    cookies[AdminSession::COOKIE] = session_cookie_options.merge(value: token, expires: session.expires_at)
    @admin_authenticated = true
    @current_admin_account = account
    success(user: account.api_json, expiresAt: session.expires_at)
  end

  def destroy
    browser_admin_session&.destroy!
    cookies.delete(AdminSession::COOKIE, **session_cookie_options)
    success(signedOut: true)
  end

  private
  def unauthorized_login
    render json: { success: false, error: 'Please sign in' }, status: :unauthorized
  end
  def invalid_credentials
    render json: { success: false, error: 'Invalid username or password' }, status: :unauthorized
  end
end
