require 'test_helper'

class AccountLoginTest < ActionDispatch::IntegrationTest
  setup do
    @previous_auth = ENV['MDM_AUTH_REQUIRED']
    ENV['MDM_AUTH_REQUIRED'] = 'true'
    SessionsController::LOGIN_STORE.clear
    @account = AdminAccount.create!(username: 'admin.saiko', password: '123456')
    @origin = { 'Origin' => 'http://localhost:3000' }
  end
  teardown { ENV['MDM_AUTH_REQUIRED'] = @previous_auth }

  def login(username: 'admin.saiko', password: '123456', headers: @origin)
    post '/api/auth/login', params: { username: username, password: password }, headers: headers, as: :json
  end

  test 'account login hashes passwords and keeps credentials out of responses' do
    assert @account.authenticate('123456')
    assert_not_equal '123456', @account.password_digest
    assert_match(/\A\$2/, @account.password_digest)
    login(username: ' ADMIN.SAIKO ')
    assert_response :success
    assert_equal 'admin.saiko', response.parsed_body.dig('data', 'user', 'username')
    assert_not response.body.include?('123456')
    assert_not response.body.include?('password_digest')
    assert_not response.body.include?('token')
    assert_match(/httponly/i, response.headers['Set-Cookie'].to_s)
    assert_match(/samesite=lax/i, response.headers['Set-Cookie'].to_s)
    token = cookies[AdminSession::COOKIE]
    assert_equal Digest::SHA256.hexdigest(token), AdminSession.last.token_digest
    get '/api/auth'
    assert_response :success
    get '/api/devices'
    assert_response :success
  end

  test 'invalid credentials do not create a session or expose account existence' do
    login(password: 'wrong')
    assert_response :unauthorized
    first = response.parsed_body
    login(username: 'missing', password: 'wrong')
    assert_response :unauthorized
    assert_equal first, response.parsed_body
    assert_equal 0, AdminSession.count
    get '/api/devices'
    assert_response :unauthorized
  end

  test 'seeded accounts enforce authentication even when the local legacy flag is false' do
    ENV['MDM_AUTH_REQUIRED'] = 'false'
    get '/api/devices'
    assert_response :unauthorized
    get '/api/auth'
    assert_response :unauthorized
    login
    assert_response :success
    get '/api/devices'
    assert_response :success
  end

  test 'logout revokes the server session and prevents cookie replay' do
    login
    token = cookies[AdminSession::COOKIE]
    delete '/api/auth/session', headers: @origin
    assert_response :success
    assert_equal 0, AdminSession.count
    cookies[AdminSession::COOKIE] = token
    get '/api/auth'
    assert_response :unauthorized
    get '/api/devices'
    assert_response :unauthorized
  end

  test 'login rotates a previous session and old cookies stop working' do
    login
    old = cookies[AdminSession::COOKIE]
    login
    latest = cookies[AdminSession::COOKIE]
    assert_not_equal old, latest
    assert_equal 1, AdminSession.count
    cookies[AdminSession::COOKIE] = old
    get '/api/auth'
    assert_response :unauthorized
    cookies[AdminSession::COOKIE] = latest
    get '/api/auth'
    assert_response :success
  end

  test 'expired sessions and disabled accounts cannot access admin data' do
    login
    travel 13.hours do
      get '/api/devices'
      assert_response :unauthorized
    end
    login
    @account.update!(active: false)
    get '/api/auth'
    assert_response :unauthorized
    get '/api/devices'
    assert_response :unauthorized
  end

  test 'browser mutations and login reject missing or untrusted origins' do
    login(headers: { 'Origin' => 'https://untrusted.example' })
    assert_response :forbidden
    login(headers: {})
    assert_response :forbidden
    login
    device = Device.create!(device_id: 'LOGIN-001', name: 'Login tablet')
    post "/api/devices/#{device.device_id}/enrollment", headers: { 'Origin' => 'https://untrusted.example' }
    assert_response :forbidden
    assert_nil device.reload.enrollment_digest
    post "/api/devices/#{device.device_id}/enrollment", headers: @origin
    assert_response :success
    delete '/api/auth/session', headers: { 'Origin' => 'https://untrusted.example' }
    assert_response :forbidden
    assert_equal 1, AdminSession.count
  end

  test 'administrator cookies do not impersonate device credentials' do
    login
    device = Device.create!(device_id: 'LOGIN-001', name: 'Login tablet', credential_digest: Digest::SHA256.hexdigest('device-secret'))
    post '/api/devices/heartbeat', params: { deviceId: device.device_id }, headers: @origin, as: :json
    assert_response :unauthorized
    get "/api/devices/#{device.device_id}/updates/current", headers: @origin
    assert_response :unauthorized
    post '/api/devices/heartbeat', params: { deviceId: device.device_id }, headers: @origin.merge('Authorization' => 'Bearer device-secret'), as: :json
    assert_response :success
  end

  test 'repeated failures lock the account temporarily and valid login resets attempts' do
    10.times do
      login(password: 'wrong')
      assert_response :unauthorized
    end
    assert_equal 10, @account.reload.failed_login_attempts
    assert @account.locked_until.future?
    login
    assert_response :too_many_requests
    travel 16.minutes do
      login
      assert_response :success
      assert_equal 0, @account.reload.failed_login_attempts
      assert_nil @account.locked_until
    end
  end

  test 'seed is idempotent and does not replace an existing password' do
    @account.update!(password: 'updated-secret')
    2.times { load Rails.root.join('db/seeds.rb') }
    assert_equal 1, AdminAccount.count
    assert @account.reload.authenticate('updated-secret')
  end
end
