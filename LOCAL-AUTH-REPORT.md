# Local auth implementation report — official Better Auth provider

Scope: this worktree (`spike/local-docker`) only. No services started, no
publishing, no credentials read or generated, primary checkout untouched.

## What was implemented

- **Dependency:** `@mastra/auth-better-auth@1.1.6` added **pinned** to
  `package.json` (`"@mastra/auth-better-auth": "1.1.6"`) via
  `npm install --save-exact`. No other dependency versions changed — the
  `package-lock.json` diff contains only additions (the new dependency and
  its transitive `better-auth` / `@better-auth/*` / `@better-fetch/fetch`
  packages); `npm` re-sorted two existing lines in `package.json`
  (`@mastra/memory`, `zod`) without changing versions.
- **Entry selection (`src/mastra/index.ts`):** a new branch sits **after**
  the explicit `MASTRACODE_AUTH_DISABLED=1` opt-out and **before** the
  default platform-deferred (`MASTRA_SHARED_API_URL`) / WorkOS branches. It
  activates **only** when `FACTORY_AUTH_PROVIDER=better-auth`:
  - Requires `BETTER_AUTH_SECRET` nonempty and >= 32 chars, otherwise the
    entry throws at load with a generation hint (`openssl rand -base64 32`).
  - Instantiates `new MastraAuthBetterAuth({ secret, signUpEnabled:
    process.env.FACTORY_SIGNUP_ENABLED === '1' })` — deferred mode, verified
    against the installed package's `dist/index.d.ts`: with `secret` and no
    `auth` instance, the provider builds its own `betterAuth()` in `init()`
    on the **host's auth database** (the same `FactoryStorage` Postgres —
    `PgFactoryStorage`/`LibSQLFactoryStorage` already power better-auth
    tables per the entry's storage comment), mounts its own handler, and
    auto-bootstraps the personal org. No custom auth database, identity
    config, or routes were added.
  - All other code, the credential-encryption path, and integration
    behavior are unchanged.
- **`.env.example`:** new "Local Better Auth (self-hosted, no external
  identity service)" section documenting `FACTORY_AUTH_PROVIDER=better-auth`,
  `BETTER_AUTH_SECRET`, and `FACTORY_SIGNUP_ENABLED` (one-time owner
  bootstrap only, loopback-only while open). `.env.schema` was left
  untouched — varlock check/build paths do not validate these vars, and the
  brief says not to touch the official schema unless validation requires it.
- **Runbook (`LOCAL-OPERATIONS.md`):** new "Local auth (Better Auth)"
  section — set `FACTORY_AUTH_PROVIDER=better-auth` +
  `BETTER_AUTH_SECRET`, boot once with `FACTORY_SIGNUP_ENABLED=1`
  (loopback/SSH-tunnel only), register the owner **through the app's own
  UI** (the user chooses their own password; the worker never reads or
  generates credentials), then remove `FACTORY_SIGNUP_ENABLED` and restart
  to close public sign-up. Auth data persists in the same Postgres
  (`state/postgres`, covered by the existing `pg_dump` backup routine);
  losing `BETTER_AUTH_SECRET` invalidates sessions only. The stale
  "Better Auth not yet configured" limitation note was updated.

## Dockerfile optimization (as permitted by the brief)

- `COPY . .` → `COPY --chown=node:node . .` (source owned by the runtime
  user at copy time).
- `chown -R node:node /app /home/node /sandboxes` → non-recursive
  `chown node:node /app/.mastra /home/node /sandboxes`. `.mastra` itself is
  owned so the runtime can write build output; build-output files may stay
  root-owned/read-only, and runtime only needs read access to
  `/app` source and `node_modules`. This removes the costly recursive chown
  of the whole tree.

## Dependency install hygiene

`node_modules` in this worktree was a **symlink** to the primary checkout's
`node_modules`. It was removed with Python `pathlib` after an
`is_symlink()` assertion (`p.unlink()` — the link only, not the target);
`npm install` then created a real worktree-local `node_modules`. Verified
after install: `/home/joelai/apps/mastra-factory/node_modules` still exists
and does **not** contain `@mastra/auth-better-auth` (primary unmutated).

## Verification (actual output)

Commands run with an empty npm userconfig
(`npm_config_userconfig=/dev/null`) to sidestep the host allow-scripts
quirk.

`npm run check` — clean:

```
> mastra-factory@0.1.0 check
> tsc --noEmit

(no output — pass)
```

`npm run build` — successful:

```
> mastra-factory@0.1.0 build
> mastra build --dir src/mastra

INFO [2026-10-10 20:41:03.981 +0000] (Mastra CLI): Copying Factory UI...
INFO [2026-10-10 20:41:04.149 +0000] (Mastra CLI): Factory UI copied successfully
INFO [2026-10-10 20:41:04.549 +0000] (Mastra CLI): Analyzing dependencies...
INFO [2026-10-10 20:41:10.555 +0000] (Mastra CLI): Optimizing dependencies...
INFO [2026-10-10 20:41:10.561 +0000] (Mastra CLI): Bundling Mastra application
INFO [2026-10-10 20:41:16.572 +0000] (Mastra CLI): Bundling Mastra done
INFO [2026-10-10 20:41:16.572 +0000] (Mastra CLI): Copying public files
INFO [2026-10-10 20:41:16.608 +0000] (Mastra CLI): Done copying public files
INFO [2026-10-10 20:41:16.608 +0000] (Mastra CLI): Wrote mastra-project.json for Software Factory project
INFO [2026-10-10 20:41:16.609 +0000] (Mastra CLI): Copying .npmrc file
INFO [2026-10-10 20:41:16.609 +0000] (Mastra CLI): Done copying .npmrc file
INFO [2026-10-10 20:41:16.610 +0000] (Mastra CLI): Updating dependency lockfile and installing dependencies
added 875 packages in 2m
INFO [2026-10-10 20:43:11.049 +0000] (Mastra CLI): Build successful, you can now deploy the .mastra/output directory to your target platform.
INFO [2026-10-10 20:43:11.049 +0000] (Mastra CLI): To start the server, run: node .mastra/output/index.mjs
```

The 16 MB generated `src/mastra/public/factory` UI copy was removed after
the build (untracked build artifact; regenerated by every `mastra build`,
including inside the Docker image build). `.mastra/` output is gitignored.

## Explicitly not done

- No services started, no containers rebuilt, nothing published.
- No credentials read or generated; no `BETTER_AUTH_SECRET` value exists
  anywhere in this worktree.
- No unrelated dependency upgrades; `.env.schema` untouched.
- Not live-verified: switching the running deployment to Better Auth
  (env change + rebuild + UI signup) is an operator step, documented in
  `LOCAL-OPERATIONS.md`.
