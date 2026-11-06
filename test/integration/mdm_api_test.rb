require "test_helper"

class MdmApiTest < ActionDispatch::IntegrationTest
  def enroll(id = "TEST-001")
    post "/api/devices/register", params: { deviceId: id, deviceName: "Test tablet", batteryLevel: 60 }, as: :json
    assert_response :success
    Device.find_by!(device_id: id)
  end

  test "fresh registration, telemetry, aliases and persistence" do
    device = enroll
    post "/api/kiosks/heartbeat", params: { deviceId: "test-001", batteryLevel: 42, isCharging: false, lockTaskState: "LOCKED" }, as: :json
    assert_response :success
    assert_equal 42, device.reload.battery_level
    assert_equal false, device.is_charging
    get "/api/v1/kiosks/TEST-001/config"
    assert_equal "LOCKED", response.parsed_body.dig("data", "lockTaskState")
    get "/api/devices"
    assert_equal 1, response.parsed_body.dig("data", "devices").size
    device.update!(last_seen: 8.minutes.ago)
    get "/api/devices/TEST-001"
    assert_equal "offline", response.parsed_body.dig("data", "status")
  end

  test "URL and maintenance changes persist with their commands despite stale heartbeats" do
    device = enroll
    patch "/api/devices/TEST-001/url", params: { targetUrl: "https://example.com/new" }, as: :json
    assert_response :success
    patch "/api/devices/TEST-001/maintenance", params: { enabled: true, message: "Updating" }, as: :json
    assert_response :success
    post "/api/devices/heartbeat", params: { deviceId: "TEST-001", currentUrl: "https://example.com/stale" }, as: :json
    assert_equal "https://example.com/new", response.parsed_body.dig("data", "targetUrl")
    assert_equal true, response.parsed_body.dig("data", "maintenanceMode")
    enroll
    assert_equal "https://example.com/new", device.reload.url
    assert_equal %w[set_url set_maintenance], device.device_commands.order(:created_at).pluck(:command_type)
  end

  test "commands are scoped, durable, acknowledged idempotently and follow rename" do
    device = enroll
    enroll("OTHER")
    post "/api/devices/TEST-001/commands", params: { type: "reload", payload: {} }, as: :json
    assert_response :success
    id = response.parsed_body.dig("data", "commandId")
    get "/api/kiosks/OTHER/commands"
    assert_equal [], response.parsed_body.dig("data", "commands")
    post "/api/devices/OTHER/commands/#{id}/ack", params: { status: "executed" }, as: :json
    assert_response :not_found
    patch "/api/devices/TEST-001", params: { newDeviceId: "RENAMED", name: "Renamed tablet" }, as: :json
    assert_response :success
    get "/api/devices/RENAMED/commands"
    assert_equal id, response.parsed_body.dig("data", "commands", 0, "id")
    2.times do
      post "/api/devices/RENAMED/commands/#{id}/ack", params: { status: "executed" }, as: :json
      assert_response :success
    end
    assert_equal "executed", DeviceCommand.find(id).status
    get "/api/devices/RENAMED/commands"
    assert_empty response.parsed_body.dig("data", "commands")
    delete "/api/devices/RENAMED"
    assert_response :success
    assert_not DeviceCommand.exists?(id)
    assert DashboardEvent.where(event_type: "device_deleted").exists?
  end

  test "bad requests and missing records return JSON failures" do
    post "/api/devices/register", params: {}, as: :json
    assert_response :bad_request
    enroll
    patch "/api/devices/TEST-001/maintenance", params: { enabled: "false" }, as: :json
    assert_response :bad_request
    patch "/api/devices/TEST-001/url", params: { url: "javascript:alert(1)" }, as: :json
    assert_response :unprocessable_entity
    assert_empty DeviceCommand.all
    get "/api/devices/MISSING"
    assert_response :not_found
    assert_equal false, response.parsed_body["success"]
  end

  test "CORS allows configured dashboard origin" do
    options "/api/devices/register", headers: { "Origin" => "http://localhost:3000", "Access-Control-Request-Method" => "POST" }
    assert_equal "http://localhost:3000", response.headers["Access-Control-Allow-Origin"]
  end
end
