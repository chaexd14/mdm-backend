# MDM Rails backend

Rails 8.1 API with PostgreSQL for the Android kiosk agent and the static Next.js dashboard.

## Local setup

Run bundle install, copy .env.example to .env, configure PostgreSQL credentials, then run:

~~~powershell
bundle exec rails db:create db:migrate
bundle exec rails server -b 0.0.0.0 -p 3001
~~~

Development/test databases are mdm_backend_development and mdm_backend_test. Set FRONTEND_ORIGINS to the dashboard browser origins. Set MDM_AUTH_REQUIRED=true and a random MDM_ADMIN_TOKEN of at least 32 characters to exercise authentication locally. Production always requires authentication and the administrator token.

The dashboard signs in with the administrator token. Register a device's exact APK Device ID, issue a one-time 15-minute enrollment code, and redeem it from the APK admin screen. Device tokens are scoped to their device; only devices can acknowledge execution. A new enrollment rotates the old token. Credentials/digests are excluded from API snapshots and event payloads.

## API

Responses use {success,data?,error?}. Device routes retain /api/devices, /api/kiosks and /api/v1/kiosks aliases; the APK uses /api/devices as its canonical route.

- GET /api/auth: administrator authentication probe.
- GET /api/devices: snapshot; POST /register: provision/update metadata; POST /heartbeat: device telemetry.
- GET/PATCH/DELETE /:deviceId: details, edits, removal. Enrolled identities cannot be renamed.
- POST /:deviceId/enrollment: administrator issues a single-use code. POST /enroll with deviceId/enrollmentCode redeems it for a deviceToken.
- GET /:deviceId/config; PATCH /:deviceId/url; PATCH /:deviceId/maintenance. Device credentials may update only their own configuration through these explicit actions.
- POST /:deviceId/commands with type/payload: create. Optional Idempotency-Key deduplicates retries.
- GET /:deviceId/commands?wait=25: bounded long polling with delivery leases and expiry.
- POST /:deviceId/commands/:commandId/ack: device reports received/executed/failed; terminal status cannot regress.
- POST /:deviceId/commands/:commandId/cancel: administrator cancels an undelivered command.
- GET /commands?page=1&limit=50&deviceId=...: history, totalCount, full pendingCount.
- GET /events: authenticated SSE with durable event IDs and Last-Event-ID replay.

Commands expire after 24 hours and have two-minute delivery leases. They use pending/received/executed/failed/cancelled/expired states. The APK deduplicates using a persistent journal and retries lost ACKs. Desired configuration is versioned separately from reported device state. Presence is healthy below one minute, stale below two minutes, then offline. Only heartbeats mark a device as seen.

One PostgreSQL LISTEN connection per web worker wakes relevant long polls when command creation commits; five-second reconciliation handles missed notifications and lease expiry. Durable dashboard events and state changes share transactions. Long polls still require adequate Puma thread capacity.

## Verification and deployment

Run bundle exec rails test. For live smoke testing set MDM_SMOKE_BASE_URL and MDM_ADMIN_TOKEN, then run node test/smoke.mjs against a running local server. The script creates and removes temporary devices.

Set DATABASE_URL, SECRET_KEY_BASE, MDM_ADMIN_TOKEN and FRONTEND_ORIGINS in production. Run migrations before starting workers. Production enforces HTTPS. Allow one extra database connection per worker for notifications; use a session-capable connection. Disable SSE proxy buffering and use timeouts above 40 seconds. Schedule bundle exec rails mdm:prune_events daily.

See [the rollout guide](../saikotech-android-mdm/docs/production-communication.md) for APK release configuration, enrollment, recovery semantics, capacity considerations, and hardware verification. No production domain, deployment, external monitoring integration, multi-tenant authorization, or per-user administrator identity provider is configured by this change.

## Readiness and sparse updates

New migrations add web_health, journal_persistence_pending and device revisions. Heartbeats publish device_telemetry patches; metadata updates remain device_updated events. Dashboard streams now share command notifications with a five-second query fallback. GET /api/devices/commands/summary returns the indexed active count without history. Deploy migrations and Rails before updating the dashboard. See [readiness and performance rollout](../saikotech-android-mdm/docs/readiness-and-performance.md).
