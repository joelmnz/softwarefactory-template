# Factory update procedure — controlled, repeatable

Operator runbook for updating the local Mastra Factory deployment at
`/home/joelai/apps/mastra-factory` (primary checkout, live runtime) from the
upstream template without breaking verified customizations. This procedure
supersedes the historical update notes at the bottom of `LOCAL-OPERATIONS.md`.

Current runtime status is tracked in the primary checkout's private
`VERIFIED-STATUS.md` — read it before every run; this file is process, not
status.

## Scope and invariants

- **Two update streams, kept separate:**
  1. **Template code** — upstream `mastra-ai/softwarefactory-template` changes
     (app source, Dockerfile, compose, scripts).
  2. **Pinned Mastra packages** — deliberate version bumps of the
     `@mastra/*` dependencies in `package.json`/`package-lock.json`
     (including `@mastra/auth-better-auth` — never skip auth packages when
     updating the Mastra set; auth and core must move compatibly together).
- **Never lose:** auth setup (Better Auth provider, `FACTORY_AUTH_PROVIDER`,
  signup gating), Docker/loopback customizations (`compose.local.yml`
  binding, nginx HTTPS deployment, CA trust), or persistent state
  (`state/postgres`, `state/home`, `state/sandboxes`).
- **No automation:** updates are performed manually. Run the read-only check
  below on a weekly cadence or when you want to update — **do not create a
  cron job, Watchtower, auto-update agent, or any scheduled task** for this.
- **No force, no rebase of published work:** `main` mirrors upstream
  fast-forward-only; published `live` is never rebased; divergence is
  stopped and reported, not overwritten.
- **No blind updates:** never run bare `npm update`, `npm audit fix --force`,
  or version-range rewrites; never `down -v`, prune, or reset.

## Remotes and layout

| Name     | Remote                                            | Role                          |
| -------- | ------------------------------------------------- | ----------------------------- |
| `upstream` | `https://github.com/mastra-ai/softwarefactory-template.git` | template source |
| `origin` | `https://github.com/joelmnz/softwarefactory-template.git`   | private fork (mirror) |

- `main` = clean mirror of `upstream/main` (fast-forward-only).
- Live deployment = separate approved branch (e.g. `live`), integrating the
  mirror plus local customizations; the primary checkout at
  `/home/joelai/apps/mastra-factory` tracks `origin/live`.

## Phase 0 — Read-only update check (no mutations)

Run from the primary checkout (or any clone with both remotes):

```sh
git fetch upstream --no-tags
git fetch origin --no-tags
git rev-list --left-right --count main...upstream/main   # expect 0 N: N ahead
git rev-list --left-right --count live...origin/live     # expect 0 0
git log --oneline main..upstream/main                    # what's new upstream
```

Dependency drift (the `npm outdated` command exits non-zero when something
is outdated — that is its signal, **not** a command failure):

```sh
npm outdated                          # nonzero exit = outdated entries
npm view @mastra/core version         # latest published, non-mutating
npm view @mastra/auth-better-auth version
npm view @mastra/factory version
```

Record findings; decide whether a template update, a package update, or both
are warranted. Proceed to the relevant stream below.

## Stream A — Template code update

1. **Mirror `main`** (fast-forward-only; refuses divergence — never force):

   ```sh
   git checkout main
   git merge --ff-only upstream/main   # if this fails, STOP and investigate
   git push origin main                # only with Joel's authorization
   ```

   If `--ff-only` fails, `main` has diverged from upstream — stop and report;
   do not reset, rebase, or force-push.

2. **Integrate into live in a fresh worktree** (never in the running primary
   checkout, never by rebasing live):

   ```sh
   git worktree add ../factory-update-$(date +%F-%H%M) live
   cd ../factory-update-*
   git merge main
   ```

   - On conflict: **stop, report, do not commit**. Resolve only with an
     explicit review — and never drop the protected customizations listed
     under "Scope and invariants" (auth, Docker/loopback, state paths).
   - Tolerate pre-existing untracked operator files in the worktree
     (`VERIFIED-STATUS.md`, `INTEGRATION-SETUP.md`, `.env.local`, etc.); if
     the merge would collide with one of them, rename the worktree copy and
     report. Never `git reset` or delete operator files.

3. **Review release/migration notes** for the upstream range
   (`main..upstream/main`) from official sources only (Mastra release notes
   / changelogs / repo commits). Note any DB migrations, env-var changes,
   or Dockerfile changes before continuing.

4. If package versions changed in the merge, run Stream B checks (below)
   against the merged tree before building a candidate.

## Stream B — Pinned Mastra package update

Run in a fresh worktree of `live` (as in Stream A step 2).

1. Choose **target versions explicitly** from official release notes; they
   must be mutually compatible (core ↔ auth ↔ factory versions move
   together). Write **exact pinned versions** into `package.json` — no
   `^`/`~` loosening, no unrelated packages, no new packages unless a
   release note requires them.
2. Inspect the **dependency key sets** before and after:

   ```sh
   npm view @mastra/core@<old> dependencies > /tmp/deps-old.json
   npm view @mastra/core@<new> dependencies > /tmp/deps-new.json
   diff /tmp/deps-old.json /tmp/deps-new.json   # explain every difference
   ```

   Repeat for every `@mastra/*` package you bump. Any package whose keys
   change unexplained = stop and investigate the release notes.
3. Lockfile changes come from `npm ci`/`npm install <pkg>@<exact>` only.
   Never `npm update`, never `npm audit fix --force`.

## Candidate build (both streams; required before rollout)

Run in the update worktree. Use a **clean install with an empty npm
userconfig** — the host `~/.npmrc` has allow-scripts related config that
leaked into builds and previously broke them:

```sh
mkdir -p /tmp/factory-update-scratch
: > /tmp/factory-update-scratch/empty-npmrc
NPM_CONFIG_USERCONFIG=/tmp/factory-update-scratch/empty-npmrc \
  npm ci --no-audit --no-fund
NPM_CONFIG_USERCONFIG=/tmp/factory-update-scratch/empty-npmrc npm run check
NPM_CONFIG_USERCONFIG=/tmp/factory-update-scratch/empty-npmrc npm run build
```

Requires Node ≥ 22.19.0 (see `engines` in `package.json`).

Then:

```sh
git diff --check                       # whitespace/conflict-marker check
git status --short                     # package.json/package-lock.json must
                                       # differ ONLY as intended; no others
git diff -- package.json package-lock.json   # review the exact diff
```

Build the candidate image with a **unique commit tag** and an OCI revision
label — never overwrite `latest` at this stage:

```sh
COMMIT=$(git rev-parse HEAD)
docker build \
  --label org.opencontainers.image.revision=${COMMIT} \
  -t mastracode-local:candidate-${COMMIT} .
docker inspect --format '{{.Id}} {{index .Config.Labels "org.opencontainers.image.revision"}}' \
  mastracode-local:candidate-${COMMIT}
```

`.dockerignore` already keeps secrets, `state/`, and `.env*` out of the
context — do not weaken it. **Before every push** (any remote), scan tracked
files for credentials; a templated, commented PEM example in docs is fine,
actual keys are not.

## Candidate review gate

Present for approval before any rollout:

- source commit SHA + branch/worktree
- new pinned `@mastra/*` versions (and the dependency-key-diff findings)
- any DB migrations included, with the official migration notes
- candidate image ID + revision label
- planned rollout gate and restore gate (below), verbatim

## Rollout (MANUAL, separately approved — do not script or automate)

Joel approves each rollout explicitly. All commands below run **as the
operator, who explicitly `cd`s into the primary checkout**:

```sh
cd /home/joelai/apps/mastra-factory
```

1. **Checkpoint active work.** Ask the owner / check the authenticated
   Factory UI or CLI whether any agent work is in flight and wait for it to
   reach a checkpoint. **Docker health checks cannot tell you this** — a
   healthy container may have sessions mid-task. Do not proceed with
   uncheckpointed work.
2. **Preserve rollback anchors** (all private, outside `state/`):
   - Tag the currently running image uniquely:

     ```sh
     RUNNING_IMG=$(docker inspect --format '{{.Image}}' mastracode-local-app-1)
     docker tag ${RUNNING_IMG} mastracode-local:rollback-$(date +%F-%H%M)
     ```

   - Record the tracked commit (`git rev-parse HEAD`) and the merge commit
     from the candidate worktree.
   - Snapshot `.env.local` and operator config (TLS files, credentials
     setup) privately, preserving permissions/ownership — never print or
     commit them.
3. **Back up PostgreSQL.** The app must be stopped (it is the DB writer;
   stopping is itself approval-gated — confirm before `stop`), keeping the
   db service up to dump from:

   ```sh
   docker compose --env-file .env.local -f compose.local.yml stop app
   mkdir -p /home/joelai/backups/factory   # OUTSIDE state/
   docker compose --env-file .env.local -f compose.local.yml exec db \
     pg_dump -U <dbuser> -d mastracode_web \
     > /home/joelai/backups/factory/db-$(date +%F-%H%M).sql
   echo $?   # must be 0 — record the exit status
   head -5 /home/joelai/backups/factory/db-*.sql   # basic archive sanity:
                                                    # must look like SQL
   ```

   A zero exit status and a readable archive are **not** proof the dump
   restores — see step 4.
4. **Restore-readiness test (required before any migration update).**
   Load the dump into a **disposable** database (fresh throwaway Postgres
   container or scratch data dir — never the live `state/postgres`) and
   verify it applies cleanly. If the restore test fails, **stop** — no
   automatic rollback, no rollout.
5. **Capture state** (app stopped; never raw-copy the live
   DB data dir — the dump in step 3 is the DB backup):

   ```sh
   cp -a state/home      /home/joelai/backups/factory/home-$(date +%F-%H%M)
   cp -a state/sandboxes /home/joelai/backups/factory/sandboxes-$(date +%F-%H%M)
   ```

   `state/sandboxes` may contain unpushed in-flight agent work — it is
   **not** disposable.
6. **Fast-forward the primary checkout** only if the fetch is clean and
   tracked work is clean:

   ```sh
   git fetch origin
   git status --short   # tolerate known untracked operator files; flag
                        # collisions; no reset
   git merge --ff-only origin/live
   ```

   Never rebased live; never forced.
7. **Swap images by retagging** (simple alternative; no compose overlay):

   ```sh
   docker tag mastracode-local:candidate-${COMMIT} mastracode-local:latest
   docker compose --env-file .env.local -f compose.local.yml config --quiet
   docker compose --env-file .env.local -f compose.local.yml \
     up -d --no-build --no-deps
   ```

   This preserves project name, network, and mount paths exactly. If only
   the app image changed and the db is still running, target just the app:
   `up -d --no-build --no-deps app`. The `config --quiet` step validates the
   interpolated compose files before any container is touched.

## Post-rollout verification (record all results in VERIFIED-STATUS.md)

```sh
docker inspect --format '{{.Image}}' mastracode-local-app-1   # == candidate ID
docker inspect --format '{{.Image}}' mastracode-local-db-1    # unchanged DB image
docker port mastracode-local-app-1                            # 127.0.0.1:4112 only
docker exec mastracode-local-app-1 sh -c 'echo $FACTORY_SIGNUP_ENABLED' \
  || docker inspect mastracode-local-app-1 \
       --format '{{range .Config.Env}}{{.}} {{end}}' | tr ' ' '\n' \
       | grep -c '^FACTORY_SIGNUP_ENABLED=1'   # expect 0; never print env
curl -s -o /dev/null -w '%{http_code}' \
  --cacert /home/joelai/apps/paperclip/tls/ca.crt \
  --resolve factory.janet.localdev:443:192.168.1.215 \
  https://factory.janet.localdev/signin          # expect 200
curl -s -o /dev/null -w '%{http_code}' \
  --cacert /home/joelai/apps/paperclip/tls/ca.crt \
  --resolve factory.janet.localdev:443:192.168.1.215 \
  https://factory.janet.localdev/api/factory/projects   # expect 401
```

Then the **owner** confirms in the browser: login works, GitHub connection
works, and one bounded real model-backed task completes end-to-end. HTTP
code checks alone do not prove authenticated functionality — do not claim it
without this confirmation.

## Restore / rollback

- **Image/source-only rollback** (no migrations ran): retag the previous
  `rollback-*` image to `latest`, restore the previous tracked commit
  (`git merge --ff-only <previous-sha>` from the recorded anchor, or
  re-checkout the recorded commit in a worktree), `up -d --no-build
  --no-deps app`. Requires the DB to be compatible with the old image.
- **If migrations ran**, restoring the old image alone is forbidden. Use the
  reviewed manual procedure: stop both writers (app **and** db), restore the
  matching DB dump, files (`state/home`, `state/sandboxes`), and `.env.local`
  snapshot from the same backup generation, then start both. Never mix a new
  DB with an old image or vice versa.
- No automatic rollback exists anywhere in this procedure; every restore is
  a deliberate, operator-approved action.

## Standing prohibitions

- No cron/scheduled updates, no Watchtower, no auto-pull.
- No public ingress, webhook, or port changes as part of an update.
- Never `docker compose down -v`, never prune images/volumes during a run.
- Never force-push, reset, or rebase `main`/`live`.
- Never push without a tracked-file credential scan.
- Never enter credentials over plain HTTP; HTTPS (`factory.janet.localdev`,
  Janet LAN Paperclip CA) or SSH tunnel only.