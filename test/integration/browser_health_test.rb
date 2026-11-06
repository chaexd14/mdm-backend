require "test_helper"
class BrowserHealthTest < ActionDispatch::IntegrationTest
  setup { @device = Device.create!(device_id: "BROWSER-001", name: "Browser tablet") }
  test "browser health and configuration application are distinct and telemetry events are sparse" do
    post "/api/devices/heartbeat", params: { deviceId: @device.device_id, webHealth: { state: "loaded", loadedUrl: "https://example.com", loadDurationMs: 420, firstContentfulPaintMs: 220, rendererCrashCount: 1 }, journalPersistencePending: true }, as: :json
    assert_response :success
    assert_equal "loaded", @device.reload.web_health["state"]
    assert_equal true, @device.journal_persistence_pending
    assert_operator @device.lock_version, :>, 0
    event = DashboardEvent.order(:id).last
    assert_equal "device_telemetry", event.event_type
    assert_equal "loaded", event.payload.dig("device", "webHealth", "state")
    assert_not event.payload["device"].key?("name")
    assert_not event.payload["device"].key?("credentialDigest")
    previous = @device.lock_version
    post "/api/devices/heartbeat", params: { deviceId: @device.device_id }, as: :json
    assert_response :success
    event = DashboardEvent.order(:id).last
    assert_not event.payload["device"].key?("webHealth")
    assert_operator @device.reload.lock_version, :>, previous
    get "/api/devices"
    snapshot = response.parsed_body.dig("data", "devices", 0)
    assert_equal @device.lock_version, snapshot["revision"]
    assert_equal "loaded", snapshot.dig("webHealth", "state")
  end
  test "summary returns only the active count without history payloads" do
    @device.device_commands.create!(command_type: "reload", payload: {})
    get "/api/devices/commands/summary"
    assert_response :success
    assert_equal 1, response.parsed_body.dig("data", "pendingCount")
    assert_not response.parsed_body["data"].key?("commands")
  end
  test "invalid browser metrics cannot corrupt the device record" do
    post "/api/devices/heartbeat", params: { deviceId: @device.device_id, webHealth: { state: "ready", loadDurationMs: -1 } }, as: :json
    assert_response :bad_request
    assert_equal({}, @device.reload.web_health)
    post "/api/devices/heartbeat", params: { deviceId: @device.device_id, webHealth: { state: "invented" } }, as: :json
    assert_response :bad_request
  end
end
