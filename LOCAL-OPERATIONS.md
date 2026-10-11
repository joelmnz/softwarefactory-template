# Local Docker operations — MastraCode Web (spike)

How to run, stop, and maintain the local Docker deployment defined by
`Dockerfile` + `compose.local.yml`. This is a self-contained deployment; it
does not touch the official `docker-compose.yml` (dev backing services).

## Deployment status: HTTPS PREPARED (not yet applied)

The LAN HTTPS reverse proxy is **PREPARED in this worktree but NOT deployed**:
no leaf certificate exists under `state/tls/`, nginx has no `factory` site,
and no runtime env change has been applied until there is actual evidence
(script output showing `nginx -t` passing, backend readiness, and the curl
checks succeeding). Do not describe the deployment as HTTPS-enabled until
`deployment/install-local-https.sh` has been run as root on the primary
checkout and its post-verification passed.

- **Prepared:** `deployment/nginx-factory.conf` (nginx site for
  `factory.janet.localdev`: :80 → 301 HTTPS, :443 TLS 1.2/1.3, LAN-only
  allowlist, proxy to loopback) and `deployment/install-local-https.sh`
  (root installer: issues/reuses a leaf cert signed by the Janet LAN
  Paperclip CA, installs nginx files, validates with `nginx -t` before any
  reload with rollback on failure, updates three `.env.local` keys, recreates
  the app, verifies readiness, then reloads nginx).
- **Current runtime (until the script is applied):** the app container still
  binds `192.168.1.215:4112` over plain HTTP (per the pre-HTTPS compose
  file in the primary checkout); see the caveat below.
- **Target (after the script runs):** the app binds `127.0.0.1:4112` only
  (this worktree's `compose.local.yml`); LAN devices reach the app at
  `https://factory.janet.localdev` through nginx.

## Current state (verified 2026-10-10)

- The Docker image was **built and is running** from the primary checkout
  at `~/apps/mastra-factory` (`mastracode-local-app-1` +
  `mastracode-local-db-1`, bound to LAN address `192.168.1.215:4112` only).
  The original
  package build (`npm ci` + check + build inside the image) succeeded.
- **Auth:** configured with the official local Better Auth provider
  (`FACTORY_AUTH_PROVIDER=better-auth`, `@mastra/auth-better-auth`).
  Login and sign-up forms are verified; the owner account is still
  pending creation.
- **No-auth mode was live-tested and does not work as a Factory:** the UI
  stalled on the loader (`/auth/me` recheck loop) and project list/create
  returned 401. Do not use or recommend `MASTRACODE_AUTH_DISABLED=1` as a
  working Factory configuration.
- **Persistence:** DB data, home, and workspace marker files survived
  container recreation. These are storage tests only — **active agent
  sessions are NOT verified** as recoverable.
- **Not yet configured:** model provider and GitHub App. No real task,
  coding session, or PR has been run through this deployment.
- **Local auth (Better Auth)** is active via the official
  `@mastra/auth-better-auth` provider — see "Local auth (Better Auth)"
  below for setup and the owner bootstrap procedure.
- Latest probe evidence and verification details:
  `~/apps/mastra-factory/VERIFIED-STATUS.md` (in the primary checkout;
  supersedes this file's initial auth-disabled spike wording).

## Local auth (Better Auth)

For fully local authentication (no Mastra platform, no WorkOS), set these
vars in `.env.local`:

```
FACTORY_AUTH_PROVIDER=better-auth
BETTER_AUTH_SECRET=<openssl rand -base64 32>   # >= 32 chars, session signing
FACTORY_SIGNUP_ENABLED=1                       # ONLY for the first boot
```

The app then uses the official `@mastra/auth-better-auth` provider in
deferred mode: it builds its Better Auth instance on the app's own auth
database — the same Postgres as `DATABASE_URL` (`state/postgres`) — and
auto-bootstraps the owner's personal organization. No separate auth
database, identity config, or external service is involved.

One-time owner bootstrap:

Registration is **disabled before the LAN deployment** (Janet ships it
disabled; there are 0 existing users, so no account exists yet). Reopen
it only for this controlled bootstrap, and only over a secure channel:

1. Temporarily set `FACTORY_SIGNUP_ENABLED=1` in `.env.local`, rebuild
   and restart the app.
2. Before entering any credentials, connect over **HTTPS** (the prepared
   nginx TLS proxy — status above — after
   `deployment/install-local-https.sh` has been applied and verified) or
   through an **encrypted SSH tunnel** — never the plain-HTTP LAN URL:

   ```sh
   ssh -L 4112:127.0.0.1:4112 joelai@192.168.1.215
   # then open http://localhost:4112 on the PC (works against the
   # loopback-bound target once the app is on 127.0.0.1:4112; before the
   # HTTPS script is applied the app is still bound to 192.168.1.215:4112,
   # so tunnel 4112:192.168.1.215:4112 instead)
   ```

   Note: `deployment/install-local-https.sh` enforces
   `FACTORY_SIGNUP_ENABLED=0`; re-open sign-up only for this bootstrap step
   and set it back to `0` afterwards (step 4).

   The tunnel encrypts its connection; the service itself stays bound
   to the LAN address.
3. Register the owner account **through the app's own sign-up UI**, choosing
   your own password. Nothing reads or generates credentials for you —
   do this yourself in the browser.
4. Remove `FACTORY_SIGNUP_ENABLED` from `.env.local` and restart the app
   (`docker compose --env-file .env.local -f compose.local.yml up -d
   --force-recreate app`). Public sign-up is then closed again and the
   deployment stays single-user.

Local auth data (users, sessions, orgs) lives in the same Postgres as all
other app state, so it is covered by the existing `state/postgres` backup
and `pg_dump` routine — losing the DB means losing the login; losing
`BETTER_AUTH_SECRET` means existing sessions cannot be verified (users
re-authenticate; no data loss).

## Prerequisites

- **GitHub App (required):** the Factory needs a self-hosted GitHub App
  (App ID, private key, client id/secret, slug) for repo access, webhooks,
  and review bots. Create one for this deployment before expecting
  GitHub-backed features to work; a partial `GITHUB_APP_*` group stays
  disabled by design. Without it, the app boots but GitHub integrations
  (Connect GitHub, repo picker, webhooks) are unavailable.
- Docker + Docker Compose v2 on the host.
- `.env.local` next to this file, generated by Janet. It must contain at
  least:
  - `DATABASE_URL=postgres://user:<POSTGRES_PASSWORD>@db:5432/mastracode_web`
    (host **must** be `db` — the compose service name; there is no host port
    to reach the DB from outside the compose network)
  - `POSTGRES_PASSWORD=<secret>` (used by both the db service and
    `DATABASE_URL`)
  - Any other app env (`MASTRACODE_PUBLIC_URL`, `MASTRACODE_AUTH_DISABLED=1`,
    `GITHUB_APP_*`, `WORKOS_*`, model keys, …). See `.env.schema` /
    `.env.example` for the full surface.
  - No secrets live in tracked sources; `.env.local` is gitignored.

## First-time setup (host, once)

Create the persistent state directories:

```sh
mkdir -p state/postgres state/home state/sandboxes
```

The host user is already uid 1000 (the app's uid), so **no `chown` is
needed** — the app can use the directories as created. Before recreating
them on an existing install, check ownership first (`ls -ln state`): the
dirs must be owned by uid 1000; if they exist with different ownership,
fix that before starting the app. `state/postgres` is owned/handled by the
db container's entrypoint.

`state/postgres` must be empty on first start (or contain a previous
postgres data dir); the postgres entrypoint initializes it.

## Start / stop / restart

```sh
# Build + start (first time, or after Dockerfile changes)
docker compose --env-file .env.local -f compose.local.yml up -d --build

# Subsequent starts
docker compose --env-file .env.local -f compose.local.yml up -d

# Stop (keeps all state in ./state). --env-file is required even for `down`:
# compose interpolates ${POSTGRES_PASSWORD:?...} when parsing the file, so it
# hard-fails without it.
docker compose --env-file .env.local -f compose.local.yml down

# Restart app only (e.g. after .env.local change)
docker compose --env-file .env.local -f compose.local.yml up -d --force-recreate app

# Restart both
docker compose --env-file .env.local -f compose.local.yml restart
```

App URL — two distinct states, keep them apart:

- **Current runtime (pre-HTTPS script):** `http://192.168.1.215:4112` — the
  running container is bound to the host LAN address (not `0.0.0.0`;
  container listens on 4111) over **plain HTTP**.
- **Target (after `deployment/install-local-https.sh` is applied and
  verified — status at the top of this file):**
  `https://factory.janet.localdev` via nginx (LAN :443, TLS 1.2/1.3,
  LAN-subnet allowlist) proxying to the app on `127.0.0.1:4112`. Plain HTTP
  to the app is then loopback-only; the :80 listener only redirects the
  Factory host to HTTPS.

**Security caveats:**

- Until the HTTPS script has actually run and its curl checks passed, the
  reachable surface is plain **HTTP** — do **not** enter passwords or other
  credentials through `http://192.168.1.215:4112`. Use the HTTPS URL (once
  live) or an SSH tunnel instead.
- Binding to a LAN address (or a loopback-behind-nginx layout) is **not**
  proof of protection from the internet — it is not a firewall boundary.
  Upstream/internet reachability depends on your router and firewall, not
  this compose setting.

For an encrypted path before HTTPS is live, use an SSH tunnel:

```sh
ssh -L 4112:192.168.1.215:4112 joelai@192.168.1.215
# then open http://localhost:4112 on the PC (the tunnel target must be the
# address the app is actually bound to: 192.168.1.215 pre-script,
# 127.0.0.1 post-script)
```

## LAN HTTPS via nginx (status: PREPARED — not deployed)

Goal: browsers on the LAN reach the Factory at
`https://factory.janet.localdev` (DNS already resolves to `192.168.1.215`)
over TLS terminated by the host nginx, with the app itself bound to
`127.0.0.1:4112`. The leaf certificate is signed by the existing local root
CA **Janet LAN Paperclip CA** (`~/apps/paperclip/tls/ca.crt`); the Paperclip
deployment and its CA key are never modified.

Apply it with one root command on the primary checkout (Joel runs this;
Janet only reviews — it recreates the app container and reloads nginx):

```sh
sudo bash /home/joelai/apps/mastra-factory/deployment/install-local-https.sh
```

What the script does (idempotent, fail-closed; safe to re-run):

1. Issues (or reuses a matching, non-expired, CA-valid) leaf cert/key under
   `state/tls/` (gitignored, mode-protected): RSA 3072, SAN
   `factory.janet.localdev`, serverAuth, random serial (the CA's serial file
   is never touched), valid ≤365d and always shorter than the CA. The CA
   private key is only referenced for signing — never copied, moved, or
   displayed.
2. Installs the leaf to `/etc/nginx/ssl/` (key 0600 root, crt 0644) and the
   Factory site to `/etc/nginx/sites-available/factory` + `sites-enabled`
   symlink; aborts on unexpected existing targets/symlinks.
3. Validates with `nginx -t` **before** any reload; on failure it removes
   the added files and leaves the running nginx untouched.
4. Backs up `.env.local` to `state/tls/` (0600) and sets exactly three keys:
   `MASTRACODE_PUBLIC_URL=https://factory.janet.localdev`,
   `MASTRACODE_ALLOWED_ORIGINS=https://factory.janet.localdev`,
   `FACTORY_SIGNUP_ENABLED=0` (secrets preserved, never printed).
5. Recreates only the `app` service (`up -d --no-build --force-recreate
   app` as joelai), polls `http://127.0.0.1:4112/signin` with finite
   retries; if the backend never comes up, it restores the `.env.local`
   backup and recreates the app on the previous env before failing.
6. Reloads nginx only after the backend is verified, then checks
   `https://factory.janet.localdev/signin` → 200 (via
   `curl --cacert ~/apps/paperclip/tls/ca.crt --resolve`) and a signed-out
   project endpoint → 401. It does **not** assert login success.

Client trust (per device, LAN only) — trust the **root CA only**
(`ca.crt`); **never** distribute, copy, or import any private key
(`ca.key` / leaf keys):

- **Windows:** double-click `ca.crt` → Install Certificate → Local Machine →
  *Trusted Root Certification Authorities*.
- **macOS:** open `ca.crt` in Keychain Access (System keychain) → set Trust
  → SSL to *Always Trust*.
- **iOS/iPadOS:** AirDrop or mail `ca.crt` → install the profile in Settings
  → then Settings → General → About → *Certificate Trust Settings* → enable
  full trust for the Janet LAN Paperclip CA.
- **Android:** Settings → Security → Encryption & credentials → *Install a
  certificate* → CA certificate → pick `ca.crt`.

Importing a root CA makes every certificate it signs trusted by that device
— only do this for your own CA on your own LAN devices.

Rollback: restore `.env.local` from the timestamped backup in `state/tls/`,
recreate the app (`up -d --no-build --force-recreate app`), and remove
`/etc/nginx/sites-enabled/factory` + `/etc/nginx/sites-available/factory`
(then `nginx -t && systemctl reload nginx` as root). Leaf cert/key under
`state/tls/` can be kept for reuse or deleted by hand — the script never
deletes state.

## Logs

```sh
docker compose --env-file .env.local -f compose.local.yml logs -f app
docker compose --env-file .env.local -f compose.local.yml logs -f db
docker compose --env-file .env.local -f compose.local.yml logs -f --tail=200
```

## State preservation & backup

All persistent state lives on the host under `./state/`:

| Directory          | Contains                                   | Back up with                      |
| ------------------ | ------------------------------------------ | --------------------------------- |
| `state/postgres`   | Postgres data dir (all app/agent data)     | `pg_dump` while running, or stop + copy the directory |
| `state/home`       | App user HOME (git config, caches)         | plain copy                        |
| `state/sandboxes`  | Per-session repo checkouts                 | **NOT disposable** — may contain active unpushed agent changes; stop the app, then copy the directory (optionally `git -C <sandbox> status` first to identify in-flight work) |

Backup the database (preferred, consistent):

```sh
docker compose --env-file .env.local -f compose.local.yml exec db \
  pg_dump -U user -d mastracode_web > backup/mastracode_web_$(date +%F).sql
```

**Never** run `docker compose --env-file .env.local -f compose.local.yml down -v` thinking it clears
caches: this stack uses bind mounts (not named volumes), but as a rule
`down -v` discards volumes and is forbidden for this deployment — state
destruction is done only by deliberate host-side deletion of `./state/*`
after a backup.

Secrets backup: `.env.local` (contains all secrets incl.
`FACTORY_CREDENTIAL_ENCRYPTION_KEY`, `POSTGRES_PASSWORD`, GitHub App keys) —
copy it to a secure location. Losing it means losing access to
encrypted-at-rest integration credentials.

## Rebuild after source changes

This worktree is a **local spike branch** (`spike/local-docker`) with **no
remote** — there is nothing to `git pull`; a plain pull just fails.
Updates arrive only via a deliberate merge from the upstream branch the
spike was cut from (base `14db15a`):

```sh
# 1. Bring in upstream changes (deliberate, reviewed — do not blind-merge)
git fetch <upstream-remote>            # or merge from the primary checkout
git merge <upstream-remote>/main       # resolve packaging files if touched

# 2. Rebuild the image (required after any source/lockfile/Dockerfile change)
docker compose --env-file .env.local -f compose.local.yml up -d --build
```

If you only changed `.env.local`, no rebuild is needed — see "Restart app
only" above.

## Limitations of this local deployment

- **Auth:** the deployment uses the official local Better Auth provider
  via `FACTORY_AUTH_PROVIDER=better-auth` (see "Local auth (Better Auth)"
  above); login/sign-up forms are verified, owner account still pending.
  `MASTRACODE_AUTH_DISABLED=1` is a supported template opt-out (checked in
  `src/mastra/index.ts`), but it was live-tested and is **not a working
  Factory**: the UI stalled on the loader and project list/create returned
  401. Port binding: after the HTTPS script is applied the app is bound to
  `127.0.0.1:4112` only, reachable on the LAN exclusively via nginx at
  `https://factory.janet.localdev` (see "LAN HTTPS via nginx" above);
  until then the running container still holds the plain-HTTP LAN binding
  `192.168.1.215:4112` (not `0.0.0.0`) — reachable by any LAN device, so
  do not enter passwords over HTTP (use the SSH tunnel), and do not treat
  the LAN binding as internet firewall protection.
- The DB is pgvector **pg17** per the spike spec (official dev compose uses
  pg18); single-node Postgres, no host port.
- Sandboxes run as local `LocalSandbox` under `/sandboxes` inside the app
  container — coding agents work in the app container's filesystem (git/gh/
  python3/build-essential are installed there), no Docker-in-Docker.
  **Isolation caveat:** these are separate directories inside one shared
  app container, not security boundaries — agents can reach the server's
  filesystem and secrets. Only connect **trusted repositories**.
  Independent VM/container sandboxes would require an official compatible
  provider.
- Resource limits: app 4 GB, db 1 GB — raise via `mem_limit` if agents run
  out of memory.
- The container entrypoint is `mastra start` directly (not `npm run start`)
  because `varlock run` requires an on-disk `.env` file, which this
  deployment deliberately does not bake into the image. Env is injected by
  compose from `.env.local`.
