# SPIKE REPORT — Local Docker packaging of MastraCode Web

- **Worktree:** `/home/joelai/code/agent-worktrees/mastra-factory/local-docker` (branch `spike/local-docker`, base `14db15a`)
- **Scope honored:** no TS/source edits, no Paperclip/Feedback Sentinel changes, no host config changes, no publishing, no services started.
- **Files added:** `Dockerfile`, `.dockerignore`, `compose.local.yml`, `LOCAL-OPERATIONS.md`, `package-lock.json` (copied verbatim), `SPIKE-REPORT.md` (this file). `.gitignore` extended with `state/`.

## What was built

### `Dockerfile`
- Base `node:22-bookworm-slim` (Node 22 Debian).
- Installs `ca-certificates curl git gh openssh-client python3 build-essential` — the toolchain coding agents need inside the app container.
- `npm ci` from the copied lockfile (npm deps + Mastra CLI retained), then `npm run check && npm run build` as image gates.
- Runtime: `HOME=/home/node`, `MASTRACODE_LOCAL_SANDBOX_ROOT` set by compose to `/sandboxes`, `NODE_ENV=production`, port 4111.
- Non-root: `USER node` (uid 1000 in the node image); `/app`, `/home/node`, `/sandboxes` chowned to uid 1000.
- **Entry deviation (explainable, no TS change):** `CMD ["node_modules/.bin/mastra", "start"]` instead of `npm run start`. Reason, verified empirically: `npm run start` wraps `mastra start` in `varlock run`, which hard-fails with `🚨 No .env files found` when no `.env` file exists on disk (`varlock run -- sh -c 'echo ok'` reproduced this in an empty dir). In this image, env is injected by compose (`env_file: .env.local`) and `.env*` is dockerignored — deliberately never baked into the filesystem. Calling the Mastra CLI directly is the correct packaging for env-injected containers.

### `.dockerignore`
Excludes `node_modules` (no trailing slash — deliberately matches the
`node_modules` **symlink** used in this worktree, which a `node_modules/`
pattern would miss), `.git/`, `.mastra/`, `state/`, `.env`/`.env.*` (keeps `.env.example`/`.env.schema`), logs, `SPIKE-*.md`, `.agents/`, `.claude/` — secrets, state, and session metadata never enter the build context.

### `compose.local.yml` (official `docker-compose.yml` untouched)
- `app`: built image, `user: '1000:1000'`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `mem_limit: 4g`, `restart: unless-stopped`, no Docker socket, port binding `127.0.0.1:4112:4111` (loopback only). Env via `env_file: .env.local` with `required: true` — **fail closed**: compose refuses to create the app container without the file (see "Revisions" below for why this changed from an earlier `required: false`).
- `db`: `pgvector/pgvector:pg17` (per spike spec; official dev compose uses pg18), `POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?...}` from `.env.local` via `compose --env-file .env.local`, **no host port**, healthcheck `pg_isready`, `mem_limit: 1g`, `restart: unless-stopped`, default caps so the postgres entrypoint can chown its bind-mounted data dir.
- Persistent bind dirs: `./state/postgres:/var/lib/postgresql/data` (pg17 declares `VOLUME /var/lib/postgresql/data`; binding the declared data dir itself, not the parent, so the image's anonymous volume can never shadow the actual DB state on the host — see "Revisions"), `./state/home:/home/node`, `./state/sandboxes:/sandboxes`.
- `MASTRACODE_AUTH_DISABLED=1` is the supported template opt-out (checked in `src/mastra/index.ts`): auth off entirely, **no per-session security isolation** — anyone reaching the port is the single operator. Acceptable only because the app is bound to host loopback 4112; documented in LOCAL-OPERATIONS.md with the WorkOS alternative.

### `package-lock.json`
Copied byte-identical (517,485 bytes, lockfileVersion 3) from `/home/joelai/apps/mastra-factory/package-lock.json` — the sole outside-file read explicitly permitted by the brief. Verified its root `dependencies`/`devDependencies` match the worktree `package.json` exactly (script check: `lockfile root matches package.json: true`). No key/secret files copied.

## Checks run (actual commands & results)

| # | Command | Result |
|---|---------|--------|
| 1 | `npm run check` (with `node_modules` symlinked to the primary checkout's node_modules for speed) | **PASS**, exit 0, no output from `tsc --noEmit` |
| 2 | `npm run build` (extra validation, symlinked deps) | First two attempts **failed** (`EALLOWSCRIPTS`) — see host quirk below; **PASS** with clean npm userconfig, `Build successful … node .mastra/output/index.mjs`; `.mastra` output deleted after validation |
| 3 | `POSTGRES_PASSWORD=test docker compose -f compose.local.yml config --quiet` (no `.env.local` exists yet) | **PASS**, exit 0 — historical only: this run predates the `env_file required: true` fix and would now fail closed (see "Revisions") |
| 4 | Temp dummy `.env.local` (only placeholder values, deleted after): `docker compose --env-file .env.local -f compose.local.yml config --quiet` | **PASS**, exit 0; rendered env shows `DATABASE_URL`, `POSTGRES_PASSWORD`, `MASTRACODE_*` wired correctly |
| 5 | `docker build` | **Deferred to Janet** per brief ("docker build or defer"); rationale: full `npm ci` (~843 packages) + `mastra build` inside the image is a long network-heavy build; the Dockerfile's build gate steps were validated on the host via #1 and #2, and every layer's failure mode identified below |

### Host-only quirk found (does not affect the image)

`npm run build` failed locally with `npm error EALLOWSCRIPTS: --allow-scripts is not allowed in project-scoped installs`. Root cause (traced via `/home/joelai/.npm/_logs/…-debug-0.log` and npm's `lib/utils/resolve-allow-scripts.js`): the host's `~/.npmrc` contains `allow-scripts=@kilocode/cli` (npm 11.17's new allow-scripts RFC). When `npm run build` spawns the Mastra CLI, npm exports all config as `npm_config_*` env vars (`npm_config_allow_scripts=@kilocode/cli` confirmed via `npm run env`); the CLI's child `npm install` in `.mastra/output` resolves that env var through the "cli/env" policy layer and throws. Workaround for local runs: `npm_config_userconfig=$(mktemp) npm run build`. Inside the Docker image this cannot occur — there is no user `.npmrc` with that key, and Node 22 ships npm 10.9 which predates the feature. Documented here so Janet isn't surprised if she rebuilds on the host.

## Explicitly not done

- No services started, no `docker compose up`, no image build/publish.
- No TS edits (`src/` untouched); the only packaging deviations (direct `mastra start` entrypoint) are config-only and explained above.
- No edits to official `docker-compose.yml`, `.env.example`, `.env.schema`.
- `SPIKE-BRIEF.md`/`SPIKE-REPORT.md` added to local ignore (`.git/info/exclude`); this report is force-added to the commit since the brief requires committing it.

## What Janet still needs to do

1. Generate `.env.local` (must include `DATABASE_URL=postgres://user:<POSTGRES_PASSWORD>@db:5432/mastracode_web`, `POSTGRES_PASSWORD`, plus `MASTRACODE_AUTH_DISABLED=1` or WorkOS config, and any `GITHUB_APP_*` group).
2. `mkdir -p state/postgres state/home state/sandboxes && sudo chown -R 1000:1000 state/home state/sandboxes`
3. `docker compose --env-file .env.local -f compose.local.yml up -d --build` → app at http://127.0.0.1:4112. Full runbook incl. logs, backup, sandbox handling, and the **never `down -v`** rule: `LOCAL-OPERATIONS.md`.
4. Updates are **not** fetched with `git pull` — `spike/local-docker` is a local branch with no remote; merge deliberately from upstream, then rebuild (see `LOCAL-OPERATIONS.md` → "Rebuild after source changes").

## Revisions (post-review fixes)

Applied after the packaging review; no other changes, no services started.

1. **pg17 data mount corrected:** `./state/postgres:/var/lib/postgresql` → `./state/postgres:/var/lib/postgresql/data`. The pg17 image declares `VOLUME /var/lib/postgresql/data`; binding only the parent risks the declared anonymous volume masking the actual DB state written to the bind mount.
2. **`--env-file .env.local` on ALL compose commands** in the runbook, including `down`, `logs`, and the `pg_dump` backup: compose interpolates `${POSTGRES_PASSWORD:?...}` whenever it parses `compose.local.yml`, so every command needs the env file or it fails.
3. **Sandboxes are NOT disposable/safe to clear:** `state/sandboxes` may contain active unpushed agent changes; the runbook now treats it as backed-up state (stop the app, copy the directory).
4. **Update path corrected:** `git pull` instructions replaced — this is a local spike branch with no remote; updates require a deliberate upstream merge followed by `up -d --build`.
5. **`node_modules` ignore matches the symlink:** `.gitignore` and `.dockerignore` now use `node_modules` (no trailing slash) — a `node_modules/` pattern only matches directories and would let the worktree's `node_modules` symlink slip into git/the build context.
6. **`env_file: .env.local` is now `required: true`** (was `required: false` for early `docker compose config` validation): the app now fails closed instead of booting without its config; `DATABASE_URL` pointing at host `db` remains mandatory at runtime.
