require "test_helper"
require "digest"

class ReliableDeliveryTest < ActionDispatch::IntegrationTest
  setup do
    @device = Device.create!(device_id: "RELIABLE-001", name: "Reliable tablet")
  end

  def command(**attributes)
    @device.device_commands.create!({ command_type: "reload", payload: {} }.merge(attributes))
  end

  test "delivery leases prevent concurrent polls and permit recovery after lease expiry" do
    item = command
    get "/api/devices/RELIABLE-001/commands"
    assert_equal item.id, response.parsed_body.dig("data", "commands", 0, "id")
    assert_equal 1, item.reload.delivery_attempts
    get "/api/devices/RELIABLE-001/commands"
    assert_empty response.parsed_body.dig("data", "commands")
    travel 121.seconds do
      get "/api/devices/RELIABLE-001/commands"
      assert_equal item.id, response.parsed_body.dig("data", "commands", 0, "id")
      assert_equal 2, item.reload.delivery_attempts
    end
  end

  test "legacy lock commands and URL payloads are normalized for renamed MDM agents" do
    item = command(command_type: 'lock_kiosk')
    assert_equal 'lock_device', item.api_json['type']
    item = command(command_type: 'unlock_kiosk')
    assert_equal 'unlock_device', item.api_json['type']
    item = command(command_type: 'set_url', payload: { kioskUrl: 'https://example.com/legacy' })
    assert_equal 'https://example.com/legacy', item.api_json.dig('payload', 'targetUrl')
  end

  test "expired commands are not delivered" do
    item = command(expires_at: 1.minute.ago)
    get "/api/devices/RELIABLE-001/commands"
    assert_empty response.parsed_body.dig("data", "commands")
    assert_equal "expired", item.reload.status
  end

  test "acknowledgements are idempotent and terminal results cannot regress" do
    item = command
    %w[received failed failed].each do |status|
      post "/api/devices/RELIABLE-001/commands/#{item.id}/ack", params: { status: status, error: "Native operation failed" }, as: :json
      assert_response :success
    end
    assert_equal "Native operation failed", item.reload.error
    post "/api/devices/RELIABLE-001/commands/#{item.id}/ack", params: { status: "executed" }, as: :json
    assert_response :conflict
    assert_equal "failed", item.reload.status
    post "/api/devices/RELIABLE-001/commands/#{item.id}/ack", params: { status: "pending" }, as: :json
    assert_response :bad_request
  end

  test "idempotency keys deduplicate creation and reject changed payloads" do
    2.times do
      post "/api/devices/RELIABLE-001/commands", params: { type: "reload" }, headers: { "Idempotency-Key" => "repeat-request" }, as: :json
      assert_response :success
    end
    assert_equal 1, @device.device_commands.count
    post "/api/devices/RELIABLE-001/commands", params: { type: "lock" }, headers: { "Idempotency-Key" => "repeat-request" }, as: :json
    assert_response :conflict
  end

  test "only undelivered commands can be cancelled" do
    item = command
    post "/api/devices/RELIABLE-001/commands/#{item.id}/cancel"
    assert_response :success
    assert_equal "cancelled", item.reload.status
    item = command
    get "/api/devices/RELIABLE-001/commands"
    post "/api/devices/RELIABLE-001/commands/#{item.id}/cancel"
    assert_response :conflict
  end

  test "invalid commands and payloads are rejected" do
    [ { type: "invented" }, { type: "set_url", payload: {} }, { type: "set_maintenance", payload: { enabled: "false" } } ].each do |payload|
      post "/api/devices/RELIABLE-001/commands", params: payload, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "reported configuration never overwrites desired configuration" do
    patch "/api/devices/RELIABLE-001/url", params: { targetUrl: "https://example.com/desired" }, as: :json
    assert_response :success
    version = @device.reload.config_version
    assert_equal version, @device.device_commands.last.payload["configVersion"]
    post "/api/devices/heartbeat", params: { deviceId: @device.device_id, currentUrl: "https://example.com/old", appliedConfigVersion: version - 1 }, as: :json
    assert_response :success
    assert_equal "https://example.com/old", @device.reload.current_url
    assert_equal "https://example.com/desired", @device.url
    assert_equal version - 1, @device.applied_config_version
    assert_equal version, response.parsed_body.dig("data", "configVersion")
  end

  test "repeating desired configuration changes does not duplicate commands" do
    2.times do
      patch "/api/devices/RELIABLE-001/url", params: { targetUrl: "https://example.com/new" }, as: :json
      assert_response :success
    end
    assert_equal 1, @device.device_commands.count
    assert_equal 2, @device.reload.config_version
  end

  test "legacy unsupported commands can be delivered and failed without blocking the queue" do
    item = command
    item.update_columns(command_type: "legacy_unknown", payload: {})
    get "/api/devices/RELIABLE-001/commands"
    assert_response :success
    assert_equal item.id, response.parsed_body.dig("data", "commands", 0, "id")
    post "/api/devices/RELIABLE-001/commands/#{item.id}/ack", params: { status: "failed", error: "Unsupported command" }, as: :json
    assert_response :success
    assert_equal "failed", item.reload.status
  end

  test "pending count covers the full queue rather than the history page" do
    55.times { command }
    get "/api/devices/commands"
    assert_equal 50, response.parsed_body.dig("data", "commands").size
    assert_equal 55, response.parsed_body.dig("data", "pendingCount")
  end

  test "credential enrollment is single use, scoped and hides secrets" do
    original_required, original_token = ENV["MDM_AUTH_REQUIRED"], ENV["MDM_ADMIN_TOKEN"]
    ENV["MDM_AUTH_REQUIRED"] = "true"
    ENV["MDM_ADMIN_TOKEN"] = "test-administrator-secret-with-at-least-32-characters"
    admin = { "Authorization" => "Bearer #{ENV['MDM_ADMIN_TOKEN']}" }
    begin
      get "/api/devices"
      assert_response :unauthorized
      post "/api/devices/RELIABLE-001/enrollment", headers: admin
      assert_response :success
      code = response.parsed_body.dig("data", "enrollmentCode")
      post "/api/devices/enroll", params: { deviceId: @device.device_id, enrollmentCode: code }, as: :json
      assert_response :success
      token = response.parsed_body.dig("data", "deviceToken")
      agent = { "Authorization" => "Bearer #{token}" }
      post "/api/devices/enroll", params: { deviceId: @device.device_id, enrollmentCode: code }, as: :json
      assert_response :unauthorized
      post "/api/devices/heartbeat", params: { deviceId: @device.device_id }, headers: agent, as: :json
      assert_response :success
      post "/api/devices/heartbeat", params: { deviceId: "OTHER" }, headers: agent, as: :json
      assert_response :unauthorized
      patch "/api/devices/RELIABLE-001/maintenance", params: { enabled: true }, headers: agent, as: :json
      assert_response :success
      patch "/api/devices/OTHER/maintenance", params: { enabled: true }, headers: agent, as: :json
      assert_response :unauthorized
      get "/api/devices", headers: agent
      assert_response :unauthorized
      post "/api/devices/RELIABLE-001/commands", params: { type: "reload" }, headers: agent, as: :json
      assert_response :unauthorized
      item = command
      post "/api/devices/RELIABLE-001/commands/#{item.id}/ack", params: { status: "executed" }, headers: admin, as: :json
      assert_response :unauthorized
      get "/api/devices", headers: admin
      assert_response :success
      assert_not response.body.include?("credentialDigest")
      assert_not response.body.include?("enrollmentDigest")
      assert_not response.body.include?(token)
      # Issuing and redeeming a new code rotates the old device credential.
      post "/api/devices/RELIABLE-001/enrollment", headers: admin
      code = response.parsed_body.dig("data", "enrollmentCode")
      post "/api/devices/enroll", params: { deviceId: @device.device_id, enrollmentCode: code }, as: :json
      post "/api/devices/heartbeat", params: { deviceId: @device.device_id }, headers: agent, as: :json
      assert_response :unauthorized
    ensure
      ENV["MDM_AUTH_REQUIRED"], ENV["MDM_ADMIN_TOKEN"] = original_required, original_token
    end
  end
end
