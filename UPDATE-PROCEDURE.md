# Factory update procedure — controlled, repeatable

Operator runbook for updating the local Mastra Factory deployment at
`/home/joelai/apps/mastra-factory` (primary checkout, live runtime) from the upstream template
without breaking verified customizations. Supersedes the historical notes in `LOCAL-OPERATIONS.md`;
runtime status lives in the private `VERIFIED-STATUS.md` in the primary checkout — read it before
every run; this file is process, not status.

## Scope and invariants

- **Two update streams, kept separate:** (1) template code from upstream `mastra-ai/softwarefactory-template`;
  (2) deliberate pinned bumps of the `@mastra/*` dependencies. Auth compatibility (core ↔
  `@mastra/auth-better-auth` ↔ factory) is a **review judgment** from release notes — not every auth
  package needs a bump every time; bump only when notes require it for compatibility.
- **Never lose:** auth setup (Better Auth provider, `FACTORY_AUTH_PROVIDER`, signup gating),
  Docker/loopback customizations (`compose.local.yml` binding, nginx HTTPS, CA trust), persistent
  state (`state/postgres`, `state/home`, `state/sandboxes`).
- **No automation:** manual only; never cron/Watchtower/auto-update tasks.
- **No force, no rebase/reset of published work:** `main` mirrors upstream fast-forward-only; `live`
  is never rebased or reset; divergence stops and reports, never overwrites.
- **No blind updates:** never bare `npm update`, `npm audit fix --force`, range rewrites, `down -v`,
  prune, or reset.
- **Never `git checkout main` in the primary operator checkout** (it is the active live root); mirror
  sync happens in an isolated worktree (Stream A). **Never wildcard `cd`** (e.g.
  `cd ../factory-update-*`); every `cd` uses an explicit recorded path.

## Remotes and layout

| Name     | Remote                                                      | Role                          |
| -------- | ----------------------------------------------------------- | ----------------------------- |
| `upstream` | `https://github.com/mastra-ai/softwarefactory-template.git` | template source               |
| `origin` | `https://github.com/joelmnz/softwarefactory-template.git`   | **public** fork; `main` mirrors upstream |

- `main` = clean fast-forward-only mirror of `upstream/main` (public fork).
- `live` = the actual published branch (not an example) integrating the mirror plus local
  customizations; the primary checkout tracks `origin/live`.

## Phase 0 — Read-only update check

**No source or runtime mutation.** `git fetch` updates local remote-tracking refs only
(`FETCH_HEAD`, `refs/remotes/*`) — expected, not a source/runtime change. Run from the primary
checkout with an explicit `cd`; verify the remotes first:

```sh
cd /home/joelai/apps/mastra-factory
git remote get-url upstream   # expect .../mastra-ai/softwarefactory-template.git
git remote get-url origin     # expect .../joelmnz/softwarefactory-template.git
git fetch upstream --no-tags && git fetch origin --no-tags
git rev-list --left-right --count main...upstream/main   # expect 0 N: N ahead
git rev-list --left-right --count live...origin/live     # expect 0 0
git log --oneline main..upstream/main                    # what's new upstream
```

Dependency drift, with an empty npm userconfig so host `~/.npmrc` cannot leak into inspections:

```sh
NPM_CONFIG_USERCONFIG=/dev/null npm outdated; echo "exit: $?"
for p in @mastra/core @mastra/auth-better-auth @mastra/factory; do
  NPM_CONFIG_USERCONFIG=/dev/null npm view "$p" version
done
```

`npm outdated` exits non-zero both when packages are outdated **and** on genuine errors (registry
unreachable, malformed output) — never treat any non-zero exit as "outdated"; read the output table
and decide from the listed packages; error output means investigate, not update. Record findings;
decide whether a template update, package update, or both are warranted.

## Stream A — Template code update

1. **Review the upstream range BEFORE advancing the mirror** (the mirror is the shared base for both
   streams):

   ```sh
   BASE=$(git merge-base origin/live upstream/main)
   git log --oneline "$BASE..upstream/main"
   ```

   Review release/migration notes for this range from official sources only; note DB migrations,
   env-var changes, and Dockerfile changes first.
2. **Mirror `main` in an isolated mirror worktree** — never `git checkout main` in the primary
   operator checkout:

   ```sh
   MIRROR=$HOME/code/agent-worktrees/mastra-factory/mirror-main
   git worktree add "$MIRROR" main    # fails safely if main is checked out elsewhere
   cd "$MIRROR"
   git merge --ff-only upstream/main  # if this fails: STOP, report, investigate
   git push origin HEAD:main          # ONLY with Joel's authorization
   ```

   If `main` is already checked out elsewhere (occupied): **stop and report**, use that existing
   worktree only after review, never force-remove it.
3. **Integrate into live in a fresh candidate worktree** (never the running primary checkout, never
   rebasing `live`; the candidate can never reuse the live checkout itself — it is already checked
   out in the primary):

   ```sh
   git fetch origin live
   STAMP=$(date +%F-%H%M)
   WORKTREE=$HOME/code/agent-worktrees/mastra-factory/update-$STAMP
   git worktree add "$WORKTREE" -b "update/$STAMP" origin/live
   cd "$WORKTREE"
   git merge main
   ```

   A fresh candidate worktree contains no operator secrets; never rename or delete primary operator
   files. On conflict: **stop, report, do not commit**; resolve only with explicit review, never
   dropping protected customizations.
4. If package versions changed in the merge, run Stream B checks against the merged tree before
   building a candidate.

## Stream B — Pinned Mastra package update

Run in the candidate worktree from Stream A step 3 (both streams share this worktree setup).

1. Choose **target versions explicitly** from official release notes; they must be mutually
   compatible (core ↔ auth ↔ factory). Write **exact pinned versions** — no `^`/`~` loosening, no
   unrelated/new packages unless a release note requires them.
2. Inspect the **local manifest key sets** before and after — the `dependencies`/`devDependencies`
   key sets of `package.json` itself, not registry metadata. Scratch is created with `mktemp -d`
   under `${TMPDIR:-$HOME/.hermes/cache/scratch}` — never `/tmp`:

   ```sh
   SCRATCH=$(mktemp -d "${TMPDIR:-$HOME/.hermes/cache/scratch}/factory-update.XXXXXX")
   KEYS='const p=require("./package.json");console.log(JSON.stringify({deps:Object.keys(p.dependencies||{}),dev:Object.keys(p.devDependencies||{})},null,2))'
   node -e "$KEYS" > "$SCRATCH/keys-before.json"
   # ... targeted edits ...
   node -e "$KEYS" > "$SCRATCH/keys-after.json"
   diff "$SCRATCH/keys-before.json" "$SCRATCH/keys-after.json"
   ```

   Node stdlib only, no secrets involved. Equivalently review `git diff -- package.json`.
   **Requirement: keys unchanged unless an approved release requirement adds/removes one; unchanged
   scopes preserved; every difference explained by the release notes.**
3. Lockfile changes come from targeted exact installs plus a clean `ci` — `npm ci` itself **never**
   updates the lockfile:

   ```sh
   : > "$SCRATCH/empty-npmrc"
   NPM_CONFIG_USERCONFIG="$SCRATCH/empty-npmrc" npm install --save-exact @mastra/core@<exact>
   # repeat per bumped runtime dep; for a CLI in devDependencies add --save-dev
   NPM_CONFIG_USERCONFIG="$SCRATCH/empty-npmrc" npm ci --no-audit --no-fund
   ```

   Never `npm update`, never `npm audit fix --force`.

## Candidate build (both streams; required before rollout)

Requires Node ≥ 22.19.0 (see `engines` in `package.json`). Use a scratch empty userconfig
(host `~/.npmrc` has allow-scripts config that previously broke builds). Initialize `SCRATCH` here,
even for a template-only flow where Stream B never ran — never assume it exists from an earlier
step:

```sh
SCRATCH=$(mktemp -d "${TMPDIR:-$HOME/.hermes/cache/scratch}/factory-update.XXXXXX")
: > "$SCRATCH/empty-npmrc"
NPM_CONFIG_USERCONFIG="$SCRATCH/empty-npmrc" npm ci --no-audit --no-fund
NPM_CONFIG_USERCONFIG="$SCRATCH/empty-npmrc" npm run check
NPM_CONFIG_USERCONFIG="$SCRATCH/empty-npmrc" npm run build
git diff --check   # catches some whitespace/conflict-marker patterns, NOT all conflict
                   # markers — always also read the full diff yourself
git status --short # tracked tree clean; only intended modifications; no unexpected
                   # untracked build inputs
git diff -- package.json package-lock.json   # review the exact diff
git add package.json package-lock.json       # only the reviewed files
git commit -m "update: <what>"               # commit BEFORE recording COMMIT below —
                                             # an OCI label is not proof the tree was clean
git status --short                           # clean tracked tree
COMMIT=$(git rev-parse HEAD)
```

The reviewed exact diff and a tracked-file credential scan (actual keys never acceptable; templated
commented examples in docs fine) happen before the commit and before any push. **Build artifact
note:** `npm run build` regenerates untracked `src/mastra/public/` (tooling output, not gitignored
in this revision). Inspect it before removing; **never run broad `git clean`**.

**Docker context warning:** the existing `.dockerignore` does **not** exclude task briefs/reports
(`FACTORY-UPDATE-*.md` etc.). If the candidate worktree contains private metadata, do not build from
it unless those files are explicitly excluded via the candidate build context or a reviewed manual
local `.dockerignore` addition (no unrelated code edits). Unique commit tag, never `latest` at this
stage; no Docker build is required for documentation-only tasks:

```sh
docker build --label org.opencontainers.image.revision=${COMMIT} \
  -t mastracode-local:candidate-${COMMIT} .
docker inspect --format '{{.Id}} {{index .Config.Labels "org.opencontainers.image.revision"}}' \
  mastracode-local:candidate-${COMMIT}
```

## Review gate and publish (separately approved)

Present for approval before any rollout: source commit SHA + branch/worktree; new pinned
`@mastra/*` versions and key-set diff findings; any DB migrations with official notes; candidate
image ID + revision label (if built); planned rollout and restore gates (below), verbatim.
Publishing to `live` is its own reviewed step after candidate acceptance and explicit permission —
this documentation task's publication is authorized separately from any future application changes:

```sh
git fetch origin live
# REVIEWED_BASE = the exact origin/live SHA recorded when the review gate approved this candidate
git merge-base --is-ancestor origin/live HEAD \
  || { echo "STOP: origin/live is not an ancestor of HEAD — reconcile; never force"; exit 1; }
# Containment is NOT proof the remote is unchanged — also compare against the reviewed base:
test "$(git rev-parse origin/live)" = "$REVIEWED_BASE" \
  || { echo "STOP: origin/live advanced past the reviewed base — reconcile (merge, re-run
        verification and build, re-review); never force"; exit 1; }
```

The ancestor test is **containment only** — it does not prove the remote is unchanged, because HEAD
may include commits beyond the reviewed base. Passing it is not enough: `origin/live` must also
equal the reviewed base exactly. If either check fails — including an advanced-but-still-ancestor
`origin/live` — **STOP**: reconcile (merge into a refreshed candidate, re-run verification and
build, re-review) — never force. Then, only with approval: `git push origin HEAD:live`.

## Rollout (MANUAL, separately approved — do not script or automate)

Joel approves each rollout explicitly. Run as the operator with an explicit
`cd /home/joelai/apps/mastra-factory`.

1. **Checkpoint active work.** Ask the owner / check the authenticated Factory UI or CLI whether
   agent work is in flight; wait for a checkpoint — Docker health checks cannot tell you this.
2. **Preserve rollback anchors** (private, outside `state/`); backup path generated once with
   restrictive permissions:

   ```sh
   umask 077
   BACKUP="/home/joelai/backups/factory/$(date +%F-%H%M)"
   mkdir -p "$BACKUP"
   APP_ID=$(docker inspect --format '{{.Id}}' mastracode-local-app-1)
   DB_ID=$(docker inspect --format '{{.Id}}' mastracode-local-db-1)
   OLD_APP_IMAGE=$(docker inspect --format '{{.Image}}' mastracode-local-app-1)
   OLD_COMMIT=$(git rev-parse HEAD)
   ROLLBACK_TAG="mastracode-local:rollback-$(date +%F-%H%M)"
   docker tag "$OLD_APP_IMAGE" "$ROLLBACK_TAG"   # record this exact tag once
   ```

   Record old **app and db container IDs**, old app image, old tracked commit. Snapshot `.env.local`,
   TLS files, and setup/config into `$BACKUP` with `cp -a` (preserves permissions/ownership) — never
   print or commit them.
3. **Back up PostgreSQL.** The app must be stopped (it is the DB writer; stopping is
   approval-gated), db service stays up. The compose env provides both `POSTGRES_USER` and
   `POSTGRES_DB`; `sh -c` expansion happens inside the container — no placeholder dbuser, no tty.
   The redirected stdout **is the private dump**: straight into the mode-0600 file (umask 077),
   never printed — no `head`, no `cat`:

   ```sh
   # validate compose config BEFORE stopping anything
   docker compose --env-file .env.local -f compose.local.yml config --quiet
   docker compose --env-file .env.local -f compose.local.yml stop app
   docker compose --env-file .env.local -f compose.local.yml exec -T db \
     sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
     > "$BACKUP/database.dump"
   echo "dump exit: $?"   # must be 0 — record it
   test -s "$BACKUP/database.dump" && wc -c < "$BACKUP/database.dump"
   docker compose --env-file .env.local -f compose.local.yml exec -T db \
     sh -c 'exec pg_restore -l /dev/stdin' \
     < "$BACKUP/database.dump" > "$BACKUP/dump.toc"
   echo "toc exit: $?"    # must be 0 — TOC metadata only, never DB data
   ```

   If the dump fails: **explicit STOP** — restart the old image only after operator approval
   (a reviewed restart); never move on.
4. **Restore-readiness test (required before any migration update).** Load the dump into a
   **disposable** Postgres container with its own throwaway volume, **no production mounts, no
   published ports**; verify it imports. A successful import is necessary, not proof of full restore
   — do not invent proof. If it fails: **stop** — no automatic rollback, no rollout.
5. **Capture state** (app stopped; never raw-copy the live Postgres data dir — the dump is the DB
   backup): `cp -a state/home "$BACKUP/home"` and `cp -a state/sandboxes "$BACKUP/sandboxes"`.
   `state/sandboxes` may contain unpushed in-flight agent work — not disposable.
6. **Fast-forward the primary checkout** only after verifying the fetched head is exactly the
   reviewed candidate (prevents deploying newer, unreviewed `origin/live`):

   ```sh
   git fetch origin live
   git rev-parse origin/live    # must equal the reviewed candidate HEAD
   git status --short           # tolerate known untracked operator files; flag collisions; no reset
   git merge --ff-only origin/live
   ```
7. **Swap images.** Compose config was already validated **before the app was stopped** in step 3;
   retag the approved candidate to `latest` only at this rollout approval gate (after the backup
   exists). Then always the **app-targeted** command — never an unqualified `up`:

   ```sh
   docker tag "mastracode-local:candidate-${COMMIT}" mastracode-local:latest
   docker compose --env-file .env.local -f compose.local.yml \
     up -d --no-build --no-deps --force-recreate app
   ```

## Post-rollout verification (record all results in VERIFIED-STATUS.md)

```sh
docker inspect --format '{{.Image}}' mastracode-local-app-1  # == candidate IMAGE ID (image SHA,
                                                             # not the container ID)
docker inspect --format '{{.Id}}' mastracode-local-db-1      # DB CONTAINER ID unchanged — not
                                                             # merely the same image
docker port mastracode-local-app-1                           # 127.0.0.1:4112 only
docker exec mastracode-local-app-1 sh -c 'echo $FACTORY_SIGNUP_ENABLED'
# must print EXACTLY 0 (signup off) — that exact value only; never fall back to dumping or
# grepping the full environment (never print env)
for path in signin:200 api/factory/projects:401; do
  p=${path%:*}; want=${path##*:}
  curl -sS -o /dev/null -w "%{http_code} ssl_verify_result=%{ssl_verify_result} $p\n" \
    --cacert /home/joelai/apps/paperclip/tls/ca.crt \
    --resolve factory.janet.localdev:443:192.168.1.215 \
    "https://factory.janet.localdev/$p"  # expect "$want" AND ssl_verify_result 0 (cert verified)
done
```

`curl -sS` surfaces TLS failures on stderr; the CA file verifies the certificate, and
`%{ssl_verify_result}` must be exactly `0` — the expected HTTP status alone is not sufficient if
the certificate did not verify. HTTP status codes
alone do **not** prove authenticated functionality. The **owner** then confirms in the browser:
login works, GitHub connection works, one bounded real model-backed task completes end-to-end —
never claim auth functionality without this confirmation.

## Restore / rollback

- **Use the exact rollback tag recorded once** in Rollout step 2 (`mastracode-local:rollback-<stamp>`)
  verbatim below.
- **Image/source-only rollback (no migrations ran):** retag the recorded rollback image to `latest`;
  run the app-targeted `up -d --no-build --no-deps --force-recreate app`. The prior SHA **cannot** be
  restored via `git merge --ff-only` (that only moves forward); `git reset`/rebase of published
  `live` is forbidden. Restore the tracked deployment config **only after review** — via a reviewed
  revert commit, or a separate old-checkout operator layout preserving the **exact same compose
  project name and bind-mount paths**; never blindly point compose at a different worktree path
  (that would create a new project and volumes). Config rollback is a reviewed decision — do not
  improvise commands. Requires the DB to be compatible with the old image.
- **If migrations ran**, restoring the old image alone is forbidden. Phases, in strict order:
  1. Keep the **app stopped** (it must not write).
  2. **Disposable restore first:** import the reviewed dump into a throwaway DB (separate volumes,
     no production mounts/ports) with the old image's tooling; verify before touching live storage.
  3. To preserve a failed generation: stop the writers **and the db** — the on-disk failed generation
     stays untouched while stopped.
  4. Restore reviewed matching config/files (`.env.local`, `state/home`, `state/sandboxes`) with
     **no active writer**.
  5. Start the live DB **only** on approved restore storage.
  6. With the app still stopped, import the dump into the live DB — the db must be **running** to
     import; never SQL against a stopped db.
  7. Verify; then start the old app image.
- Never delete/reset data (`down -v`, volume removal, TRUNCATE/DROP) without additional explicit
  approval and exact named targets.

## Standing prohibitions

- No cron/scheduled updates, no Watchtower, no auto-pull; no public ingress, webhook, or port
  changes as part of an update.
- Never `docker compose down -v`; never prune images/volumes during a run; never force-push, reset,
  or rebase `main`/`live`.
- Never `git checkout main` in the primary operator checkout; never wildcard `cd`; never broad
  `git clean`.
- Never push without a tracked-file credential scan; never print DB dump contents, environment
  variables, or credential files.
- Never enter credentials over plain HTTP; HTTPS (`factory.janet.localdev`, Janet LAN Paperclip CA)
  or SSH tunnel only.
