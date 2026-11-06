import assert from 'node:assert/strict';
const base = process.env.MDM_SMOKE_BASE_URL || 'http://127.0.0.1:3001';
const adminToken = process.env.MDM_ADMIN_TOKEN || '';
const credentials = new Map();
const adminHeaders = adminToken ? { Authorization: 'Bearer ' + adminToken } : {};
const id = `SMOKE-${Date.now()}`;
const other = `${id}-OTHER`;
async function api(path, method = 'GET', body, deviceId) {
  const response = await fetch(base + path, { method, headers: { 'Content-Type': 'application/json', Origin: 'http://localhost:3000', ...(deviceId ? { Authorization: 'Bearer ' + credentials.get(deviceId) } : adminHeaders) }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30000) });
  assert.equal(response.headers.get('access-control-allow-origin'), 'http://localhost:3000');
  const data = await response.json();
  assert.equal(data.success, true, JSON.stringify(data));
  return data.data;
}
const controller = new AbortController();
let reader;
try {
  await api('/api/devices/register', 'POST', { deviceId: id, name: 'Temporary API smoke test' });
  await api('/api/devices/register', 'POST', { deviceId: other, name: 'Temporary isolation test' });
  for (const deviceId of [id, other]) {
    const enrollment = await api('/api/devices/' + deviceId + '/enrollment', 'POST');
    const result = await api('/api/devices/enroll', 'POST', { deviceId, enrollmentCode: enrollment.enrollmentCode });
    credentials.set(deviceId, result.deviceToken);
  }
  const stream = await fetch(base + '/api/devices/events', { signal: controller.signal, headers: adminHeaders });
  assert.equal(stream.headers.get('content-type'), 'text/event-stream');
  reader = stream.body.getReader();
  let eventText = '';
  const decoder = new TextDecoder();
  async function readUntil(predicate) {
    const limit = Date.now() + 10000;
    while (!predicate(eventText)) {
      assert.ok(Date.now() < limit, 'SSE event timeout');
      const next = await reader.read();
      assert.equal(next.done, false);
      eventText += decoder.decode(next.value);
    }
  }
  await readUntil(s => s.includes('event: connected'));
  const pending = api(`/api/devices/${id}/commands?wait=5`, 'GET', undefined, id);
  await new Promise(resolve => setTimeout(resolve, 400));
  const command = await api(`/api/devices/${id}/commands`, 'POST', { type: 'reload' });
  const result = await pending;
  assert.equal(result.commands[0].id, command.commandId);
  await readUntil(s => s.includes(command.commandId));
  assert.ok(eventText.includes('event: command_created'));
  const isolation = await api(`/api/devices/${other}/commands`, 'GET', undefined, other);
  assert.equal(isolation.commands.length, 0);
  await api(`/api/kiosks/${id}/commands/${command.commandId}/ack`, 'POST', { status: 'executed' }, id);
  await readUntil(s => s.includes('event: command_updated'));
  await api(`/api/devices/${id}/maintenance`, 'PATCH', { enabled: true, message: 'Smoke test' });
  const config = await api(`/api/v1/kiosks/${id}/config`);
  assert.equal(config.maintenanceMode, true);
  await api('/api/devices/heartbeat', 'POST', { deviceId: id, webHealth: { state: 'loaded', loadedUrl: 'https://example.com', loadDurationMs: 350, rendererCrashCount: 0 } }, id);
  await readUntil(s => s.includes('event: device_telemetry'));
  console.log('PASS: authenticated enrollment, live SSE, cross-request long poll, device isolation, ACK, maintenance, aliases and CORS');
} finally {
  controller.abort();
  if (reader) await reader.cancel().catch(() => {});
  for (const device of [id, other]) {
    await api(`/api/devices/${device}`, 'DELETE').catch(() => {});
  }
}
