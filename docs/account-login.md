# Dashboard account login

The dashboard sign-in screen now accepts a username and password, using the existing SaikoTech red/white theme. The Android device enrollment credential flow remains separate.

## Initial account

From `E:\mdm-backend`, run:

```powershell
bundle install
bundle exec rails db:migrate
bundle exec rails db:seed
```

The seed creates one initial account:

- Username: `admin.saiko`
- Password: `123456`

Passwords are stored as bcrypt hashes. Re-running seeds finds the existing account and preserves its current password. `MDM_SEED_ADMIN_PASSWORD` can override the password only when the account is first created. There is no public account-registration endpoint.

The development database was migrated and seeded as part of this implementation, and exactly one account was verified. Test database migrations were applied separately. Deployments need to run their own migrations/seeds and restart the Rails process after updating bundled gems/middleware.

## Browser sessions

- `POST /api/auth/login` accepts JSON `{ "username": "admin.saiko", "password": "123456" }`.
- `GET /api/auth` restores the current account session; an absent, expired, revoked or disabled-account session returns 401.
- `DELETE /api/auth/session` revokes the database session and clears the browser cookie.

The API issues a random opaque session cookie with `HttpOnly`, path `/`, a 12-hour absolute expiry, `SameSite=Lax` by default, and `Secure` in production or HTTPS requests. Only the token's SHA-256 digest is stored in the database. No session token or password is returned in the response body or stored in browser local/session storage. Signing in rotates the previous browser session; sign-out revokes it server-side. Expired sessions require sign-in again.

The dashboard sends requests with `credentials: include`, including its SSE connections. A protected API 401 returns the dashboard to the login form. The sign-in flow checks that the browser accepted its cookie before opening the fleet view.

Cookie-authenticated mutations, login and logout require an `Origin` matching `FRONTEND_ORIGINS` or the API's own origin. CORS now allows credentials for the explicitly configured frontend origins. Set `FRONTEND_ORIGINS` to the actual frontend URL(s), with scheme and port. Use consistent hostnames locally: `http://localhost:3000` with API `http://localhost:3001`, rather than mixing `localhost` and `127.0.0.1`.

For production, use HTTPS and preferably dashboard/API hostnames under the same site. Set `MDM_SESSION_SAME_SITE=none` only when HTTPS cross-site cookies are required; browser restrictions on third-party cookies can still affect such deployments. The default is `lax`.

## Access controls

Seeding an account enables API authentication even if the legacy development setting `MDM_AUTH_REQUIRED=false` is present. Production always requires API authentication. The legacy unseeded local development behavior is retained for existing test/development integrations. The optional deployment `MDM_ADMIN_TOKEN` remains supported for existing API automation; the dashboard no longer asks users for that token.

Administrator cookies cannot authenticate device-only heartbeat, command acknowledgement, or updater endpoints. Those continue to require the enrolled device's credential. Account-authenticated mutations record the administrator username in the existing mutation audit log. Passwords and tokens are filtered from Rails parameter logs.

Ten failed sign-in attempts lock a known account for 15 minutes using database-backed counters; successful login resets those counters. A bounded in-process limiter additionally allows 15 login requests per IP per three minutes. Unknown usernames return the same credential error as incorrect passwords and perform a dummy bcrypt check.

## Validation

Backend suite: 40 tests, 246 assertions, all passing. New tests exercise hashed passwords, valid/invalid login, session cookies, session rotation, logout/replay rejection, expiry, disabled accounts, origin enforcement, login throttling, seed idempotence, local auth protection and administrator/device separation. The dashboard production build, TypeScript and lint of changed frontend files passed. The seeded credentials were exercised against the running local API: login, session restore, fleet access, logout, and subsequent 401 all passed.
