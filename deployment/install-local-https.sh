#!/usr/bin/env bash
# install-local-https.sh — apply the prepared LAN HTTPS setup for Factory.
#
# PREREQUISITES / CONTRACT
# - Runs ONLY on the primary checkout at /home/joelai/apps/mastra-factory
#   (this script resolves its own directory and refuses anywhere else; copy
#   or merge the `deployment/` files into the primary checkout first).
# - Invoked as root by Joel:
#     sudo bash /home/joelai/apps/mastra-factory/deployment/install-local-https.sh
#   All docker interactions are done as joelai via `runuser` (joelai has
#   docker access; state/ is uid-1000-owned).
# - Signs the leaf certificate with the existing "Janet LAN Paperclip CA":
#     CA cert: /home/joelai/apps/paperclip/tls/ca.crt
#     CA key:  /home/joelai/apps/paperclip/tls/ca.key   (only access-tested
#              with a stat-level readability check and passed BY PATH to
#              openssl for signing — never copied, moved, displayed, or
#              read byte-wise; the CA serial file is never touched because
#              signing uses an explicit random -set_serial)
# - Idempotent: reuses a matching, non-expired, CA-valid leaf cert/key pair
#   under state/tls/ (gitignored) on rerun; re-installs nginx files safely;
#   re-asserts the three .env.local keys (backup first). The app is always
#   reconciled via `up -d --no-build app`: identical env content does NOT
#   prove the running container already holds the loopback binding, and
#   compose recreates only when its config actually differs (a fully
#   reconciled rerun is a no-op).
# - Managed-site marker: the installed Factory nginx site carries a
#   `MANAGED-BY: install-local-https.sh` marker. If a pre-existing
#   sites-available/factory lacks it, the script refuses to touch it
#   (unmanaged site — likely hand-written or from another tool).
# - Fail closed: a baseline `nginx -t` must pass BEFORE any file is written;
#   every managed artifact (site file, enabled symlink, installed leaf
#   cert/key) is backed up under state/tls/ before overwrite; on ANY
#   pre-reload failure an EXIT trap restores all of them, .env.local is
#   restored from its backup and the app is reconciled back on the previous
#   env (the rollback is guarded so it never runs twice; the original exit
#   code is preserved).
#   compose.local.yml binds the app to 127.0.0.1:4112, so after a rollback
#   the app STAYS on the loopback binding (plain-HTTP LAN access is NOT
#   restored; nginx was never reloaded).
# - Strict post-reload verification: exit non-zero unless
#     https://factory.janet.localdev/signin               -> 200
#     https://factory.janet.localdev/api/factory/projects -> 401 (signed out)
# - No global CA trust changes, no client installs, no DNS changes. Does not
#   assert login success (only HTTP-level readiness/enforcement).
set -euo pipefail
umask 077

log() { printf '[install-local-https] %s\n' "$*"; }
die() { printf '[install-local-https] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- pre-flight
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PRIMARY="/home/joelai/apps/mastra-factory"
if [[ "$ROOT" != "$PRIMARY" ]]; then
  die "this script must live in the primary checkout at $PRIMARY (got $ROOT); merge the HTTPS worktree first"
fi
[[ $EUID -eq 0 ]] || die "must run as root (sudo bash $PRIMARY/deployment/install-local-https.sh)"
[[ $(id -u joelai 2>/dev/null) ]] || die "user joelai does not exist"

CA_CERT="/home/joelai/apps/paperclip/tls/ca.crt"
CA_KEY="/home/joelai/apps/paperclip/tls/ca.key"
[[ -r "$CA_CERT" ]] || die "CA cert $CA_CERT not readable"
# Readability check only: a stat-level access test. The CA key's CONTENTS are
# never copied, moved, displayed, or read by this script — openssl is handed
# the path alone when signing the leaf.
[[ -r "$CA_KEY" ]] || die "CA key $CA_KEY not accessible (contents are never read by this script; only the path is passed to openssl for signing)"

STATE_DIR="$ROOT/state/tls"
NGINX_SSL_DIR="/etc/nginx/ssl"
LEAF_CRT="$STATE_DIR/factory.janet.localdev.crt"
LEAF_KEY="$STATE_DIR/factory.janet.localdev.key"
LEAF_CSR="$STATE_DIR/factory.janet.localdev.csr"
LEAF_EXT="$STATE_DIR/factory.janet.localdev.ext"
SITES_AVAILABLE="/etc/nginx/sites-available/factory"
SITES_ENABLED="/etc/nginx/sites-enabled/factory"
HOST="factory.janet.localdev"
APP_URL="https://factory.janet.localdev"
MARKER="MANAGED-BY: install-local-https.sh"

COMPOSE=(docker compose --env-file "$ROOT/.env.local" -f "$ROOT/compose.local.yml" --project-directory "$ROOT")

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

# Baseline: the on-disk nginx config must be valid BEFORE this script writes
# anything, so restoring our additions is provably sufficient on rollback.
if ! nginx -t >/dev/null 2>&1; then
  nginx -t 2>&1 | sed 's/^/[install-local-https] baseline: /' >&2 || true
  die "baseline nginx -t FAILED — the config was already broken before this script ran; fix it manually first (nothing was written)"
fi
log "baseline nginx -t passed (pre-existing config is valid)"

# The compose file must already bind the app to loopback (the HTTPS worktree
# change); otherwise recreating the app would leave the old LAN HTTP binding
# and the readiness check below would pass against the wrong surface.
grep -q "127.0.0.1:4112:4111" "$ROOT/compose.local.yml" \
  || die "$ROOT/compose.local.yml does not bind 127.0.0.1:4112:4111 — merge the HTTPS worktree into this checkout first"

# Is the Factory currently running? Do not "fix" a stopped deployment here;
# recreating a stopped app would silently start it in a half-configured env.
if ! runuser -u joelai -- "${COMPOSE[@]}" ps --status running --services | grep -qx app; then
  die "Factory app container is not currently running — start it first (docker compose --env-file .env.local -f compose.local.yml up -d) and re-run this script"
fi
log "pre-flight OK: running as root, primary checkout, CA present, app container running"

# ------------------------------- managed-artifact backups + EXIT-trap rollback
# Everything this script may overwrite under /etc/nginx is backed up first;
# if we exit non-zero BEFORE the nginx reload, the trap restores all of it.
BACKUP_DIR=""
MANIFEST=""
ARMED=0
# Env rollback state (declared with the trap state so the EXIT trap can
# restore .env.local on ANY pre-reload failure, including ones the inline
# handlers below never see, e.g. a failed pre-reload nginx -t or a set -e hit):
#   ENV_TOUCHED            — .env.local backup taken → env rollback is armed
#   ENV_ROLLED_BACK        — dedupe guard: env already restored once
#   APP_RECREATE_ATTEMPTED — the app was (attempted to be) run on the new env;
#                            only then must the rollback reconcile it
ENV_FILE=""
ENV_BACKUP=""
ENV_TOUCHED=0
ENV_ROLLED_BACK=0
APP_RECREATE_ATTEMPTED=0
ensure_backup_dir() {
  [[ -n "$BACKUP_DIR" ]] && return 0
  BACKUP_DIR="$STATE_DIR/pre-change-backup-$(date +%Y%m%d-%H%M%S)"
  MANIFEST="$BACKUP_DIR/manifest"
  mkdir -m 700 -p "$BACKUP_DIR/files"
  : > "$MANIFEST"
  ARMED=1
  log "backing up managed nginx/ssl artifacts to $BACKUP_DIR before overwrite"
}
backup_artifact() { # $1 = live path (file or symlink); records 'absent' if not there yet
  local p="$1"
  ensure_backup_dir
  if [[ -L "$p" ]]; then
    printf 'symlink\t%s\t%s\n' "$p" "$(readlink "$p")" >> "$MANIFEST"
  elif [[ -e "$p" ]]; then
    cp -p --parents "$p" "$BACKUP_DIR/files/"
    printf 'file\t%s\t-\n' "$p" >> "$MANIFEST"
  else
    printf 'absent\t%s\t-\n' "$p" >> "$MANIFEST"
  fi
}
restore_managed() {
  local kind p arg
  while IFS=$'\t' read -r kind p arg; do
    [[ -n "${kind:-}" ]] || continue
    case "$kind" in
      absent)  rm -f "$p" ;;
      symlink) rm -f "$p"; ln -s "$arg" "$p" ;;
      file)    rm -f "$p"; cp -p "$BACKUP_DIR/files$p" "$p" ;;
    esac
  done < "$MANIFEST"
}
on_exit() {
  local rc=$?
  trap - EXIT
  if [[ $rc -ne 0 ]]; then
    if [[ $ARMED -eq 1 ]]; then
      log "pre-reload failure (rc=$rc) — restoring prior nginx/ssl state from $BACKUP_DIR"
      restore_managed
      if nginx -t >/dev/null 2>&1; then
        log "rollback: on-disk nginx config matches the baseline again (nginx was NEVER reloaded, running config untouched)"
      else
        log "WARNING: nginx -t still fails after restore — investigate /etc/nginx manually (baseline had passed, so the drift is unexpected)"
      fi
    fi
    if [[ $ENV_TOUCHED -eq 1 ]]; then
      restore_env_and_app
    fi
  fi
  exit "$rc"   # preserve the original exit code through the trap
}
trap on_exit EXIT

# ------------------------------------------------------------ leaf cert: reuse or issue
# CA expiry — the leaf must expire strictly BEFORE the CA.
CA_END_RAW="$(openssl x509 -in "$CA_CERT" -noout -enddate | cut -d= -f2-)"
CA_END_EPOCH="$(date -d "$CA_END_RAW" +%s)"
NOW_EPOCH="$(date +%s)"
CA_REMAINING_DAYS=$(( (CA_END_EPOCH - NOW_EPOCH) / 86400 ))
[[ $CA_REMAINING_DAYS -gt 30 ]] || die "CA expires in ${CA_REMAINING_DAYS}d — refusing to issue a leaf that would outlive it"
DAYS=$(( CA_REMAINING_DAYS - 7 )); [[ $DAYS -gt 365 ]] && DAYS=365
log "CA valid until $CA_END_RAW; issuing leaf for ${DAYS}d"

reuse_existing_leaf() {
  [[ -s "$LEAF_CRT" && -s "$LEAF_KEY" ]] || return 1
  openssl x509 -in "$LEAF_CRT" -noout -checkend "$(( 30*86400 ))" >/dev/null 2>&1 || return 1          # not expired within 30d
  openssl x509 -in "$LEAF_CRT" -noout -ext subjectAltName 2>/dev/null | grep -qi "DNS:$HOST" || return 1
  openssl verify -CAfile "$CA_CERT" -purpose sslserver "$LEAF_CRT" >/dev/null 2>&1 || return 1
  # key/cert match: compare public keys
  diff <(openssl x509 -in "$LEAF_CRT" -noout -pubkey 2>/dev/null) \
       <(openssl pkey -in "$LEAF_KEY" -pubout 2>/dev/null) >/dev/null 2>&1 || return 1
  return 0
}

if reuse_existing_leaf; then
  log "reusing existing leaf cert/key under $STATE_DIR (valid, CA-signed, key matches)"
else
  log "issuing new leaf certificate for $HOST (RSA 3072, serverAuth, random serial)"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$LEAF_KEY" >/dev/null 2>&1
  chmod 600 "$LEAF_KEY"
  openssl req -new -key "$LEAF_KEY" -out "$LEAF_CSR" \
    -subj "/O=Janet LAN/CN=$HOST" >/dev/null 2>&1
  cat > "$LEAF_EXT" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$HOST
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
  # Random explicit serial → the CA's .srl serial file is never read/written.
  SERIAL="0x$(openssl rand -hex 16)"
  openssl x509 -req -in "$LEAF_CSR" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" \
    -set_serial "$SERIAL" -days "$DAYS" -extfile "$LEAF_EXT" \
    -out "$LEAF_CRT" >/dev/null 2>&1
  chmod 644 "$LEAF_CRT"
  rm -f "$LEAF_CSR"
  openssl verify -CAfile "$CA_CERT" -purpose sslserver "$LEAF_CRT" >/dev/null \
    || die "newly issued leaf failed CA verification (CA key untouched — passed by path only; inspect $STATE_DIR and remove the rejected cert manually)"
  log "issued leaf: $(openssl x509 -in "$LEAF_CRT" -noout -subject -enddate | tr '\n' ' ')"
fi

# ---------------------------------------------------- install nginx site file
# Refuse on unexpected pre-existing targets / symlink conflicts / unmanaged sites.
if [[ -e "$SITES_ENABLED" || -L "$SITES_ENABLED" ]]; then
  if [[ -L "$SITES_ENABLED" && "$(readlink -f "$SITES_ENABLED")" == "$SITES_AVAILABLE" ]]; then
    log "sites-enabled/factory already symlinked to sites-available/factory (rerun)"
  else
    die "$SITES_ENABLED already exists ($(ls -ld "$SITES_ENABLED")) — unexpected target; refusing to touch it"
  fi
fi
if [[ -e "$SITES_AVAILABLE" && ! -f "$SITES_AVAILABLE" ]]; then
  die "$SITES_AVAILABLE exists and is not a regular file — refusing to overwrite"
fi
if [[ -f "$SITES_AVAILABLE" ]] && ! grep -q "$MARKER" "$SITES_AVAILABLE"; then
  die "$SITES_AVAILABLE exists but lacks the '$MARKER' marker — it is NOT managed by this script; refusing to overwrite an unmanaged Factory site"
fi
grep -q "$MARKER" "$ROOT/deployment/nginx-factory.conf" \
  || die "source conf $ROOT/deployment/nginx-factory.conf is missing the managed-site marker — refusing to install unmarked config"

backup_artifact "$SITES_AVAILABLE"
if [[ -e "$SITES_ENABLED" || -L "$SITES_ENABLED" ]]; then
  backup_artifact "$SITES_ENABLED"   # existing correct symlink, preserved on rollback
fi
install -m 0644 "$ROOT/deployment/nginx-factory.conf" "$SITES_AVAILABLE"
if [[ ! -e "$SITES_ENABLED" && ! -L "$SITES_ENABLED" ]]; then
  backup_artifact "$SITES_ENABLED"   # records 'absent' before we create the link
  ln -s "$SITES_AVAILABLE" "$SITES_ENABLED"
fi
log "nginx site installed: $SITES_AVAILABLE (symlinked from $SITES_ENABLED if newly created)"

# ------------------------------------------------- install nginx leaf cert/key
mkdir -p "$NGINX_SSL_DIR"; chmod 755 "$NGINX_SSL_DIR"
NGINX_SSL_CRT="$NGINX_SSL_DIR/$HOST.crt"
NGINX_SSL_KEY="$NGINX_SSL_DIR/$HOST.key"
backup_artifact "$NGINX_SSL_CRT"
backup_artifact "$NGINX_SSL_KEY"
install -m 0644 "$LEAF_CRT" "$NGINX_SSL_CRT"
install -m 0600 -o root -g root "$LEAF_KEY" "$NGINX_SSL_KEY"
log "installed leaf to $NGINX_SSL_DIR (crt 0644, key 0600 root:root)"

# --------------------------------- validate BEFORE reload; EXIT-trap rollback
if ! nginx -t; then
  die "nginx -t failed with the Factory site enabled; config changes rolled back by the exit trap, running nginx untouched (no reload happened)"
fi
log "nginx -t passed"

# ------------------------------------- runtime env: backup + 3 keys, atomic edit
ENV_FILE="$ROOT/.env.local"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE missing"
ENV_BACKUP="$STATE_DIR/.env.local.backup-$(date +%Y%m%d-%H%M%S)"
cp -p "$ENV_FILE" "$ENV_BACKUP"; chmod 600 "$ENV_BACKUP"
ENV_TOUCHED=1   # from here on, the EXIT trap restores .env.local on any failure
log ".env.local backed up to $ENV_BACKUP (values never printed; rollback armed)"

set_env_key() { # file KEY VALUE — replace existing KEY= line or append; comments preserved.
  # Temp file lives under state/tls (same filesystem as $ROOT) so the final
  # mv is an atomic same-filesystem rename, never a cross-device copy.
  # Ownership and mode of the live file are preserved via --reference.
  local file="$1" key="$2" value="$3" tmp
  tmp="$STATE_DIR/.env.local.edit.$$"
  if ! awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    $0 ~ "^" key "=" { print key "=" value; replaced = 1; next }
    { print }
    END { if (!replaced) print key "=" value }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    die "env edit failed for $key (live file untouched)"
  fi
  chown --reference "$file" "$tmp"
  chmod --reference "$file" "$tmp"
  mv -f "$tmp" "$file"
}
set_env_key "$ENV_FILE" "MASTRACODE_PUBLIC_URL" "$APP_URL"
set_env_key "$ENV_FILE" "MASTRACODE_ALLOWED_ORIGINS" "$APP_URL"
set_env_key "$ENV_FILE" "FACTORY_SIGNUP_ENABLED" "0"
[[ "$(grep -c '^MASTRACODE_PUBLIC_URL=' "$ENV_FILE")" -eq 1 && "$(grep -c '^MASTRACODE_ALLOWED_ORIGINS=' "$ENV_FILE")" -eq 1 && "$(grep -c '^FACTORY_SIGNUP_ENABLED=' "$ENV_FILE")" -eq 1 ]] \
  || die ".env.local key assertion failed after edit — the EXIT trap restores the backup"
chmod 600 "$ENV_FILE"

ENV_CHANGED=0
if cmp -s "$ENV_BACKUP" "$ENV_FILE"; then
  log ".env.local already carries the target values (app service still reconciled below — the running container may predate the loopback binding)"
else
  ENV_CHANGED=1
  log ".env.local updated: MASTRACODE_PUBLIC_URL / MASTRACODE_ALLOWED_ORIGINS = $APP_URL, FACTORY_SIGNUP_ENABLED = 0"
fi

# ------------------------------------ reconcile app as joelai; verify readiness
# Idempotent rollback: restores .env.local and (if the app was ever run on
# the new env) reconciles it back onto the previous env. Guarded by
# ENV_ROLLED_BACK so the EXIT trap and the inline failure handlers below
# never perform the restore twice.
restore_env_and_app() {
  [[ $ENV_ROLLED_BACK -eq 1 ]] && return 0
  ENV_ROLLED_BACK=1
  log "restoring .env.local from backup"
  cp -p "$ENV_BACKUP" "$ENV_FILE"; chmod --reference "$ENV_BACKUP" "$ENV_FILE"
  if [[ $APP_RECREATE_ATTEMPTED -eq 1 ]]; then
    # Env-file content is part of compose's service config, so this
    # reconciles the container back onto the previous env (recreating it
    # if it was ever run on the new env).
    runuser -u joelai -- "${COMPOSE[@]}" up -d --no-build app \
      || log "WARNING: restore-recreate of app failed — check docker compose logs manually"
  fi
  # NOTE: compose.local.yml binds 127.0.0.1:4112, so after this rollback the
  # app STAYS on the loopback binding — plain-HTTP LAN access is NOT restored
  # (and nginx was never reloaded). LAN reachability is lost until the script
  # is re-run successfully or the compose binding is changed explicitly.
}
# An env identical to the backup does NOT prove the RUNNING container already
# has the loopback binding / the new env — a pre-HTTPS container may still be
# bound to 192.168.1.215:4112. `up -d --no-build app` is idempotent: compose
# reconciles the binding/env and recreates the container only when its config
# actually differs (no --force-recreate, so a fully reconciled rerun is a no-op).
APP_RECREATE_ATTEMPTED=1
if ! runuser -u joelai -- "${COMPOSE[@]}" up -d --no-build app; then
  restore_env_and_app
  die "app reconcile failed; .env.local restored, app reconciled back on previous env (loopback binding kept), nginx NOT reloaded"
fi

READY=0
TRIES=30   # full budget: the reconcile above may have recreated the container
for i in $(seq 1 "$TRIES"); do
  if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:4112/signin; then READY=1; break; fi
  sleep 2
done
if [[ $READY -ne 1 ]]; then
  restore_env_and_app
  die "backend did not become ready at http://127.0.0.1:4112/signin within 60s; .env.local restored, app reconciled back on previous env (loopback binding kept), nginx NOT reloaded"
fi
log "backend ready on 127.0.0.1:4112 (signed-out /signin returned 200)"

# ------------------------------------------------------- reload nginx (last)
if ! nginx -t; then
  die "pre-reload nginx -t failed — config NOT reloaded, running nginx untouched; exit trap restores the managed files AND .env.local (app reconciled back if it was run on the new env)"
fi
ARMED=0   # past this point nothing is rolled back automatically (reload makes it live)
systemctl reload nginx || die "nginx reload failed — config is valid on disk; check systemctl status nginx"

# ------------------------------------------------------ strict verification
# REQUIRED: both must hold or the script exits non-zero. No candidate-path
# probing: the exact endpoints below are mandatory.
tls_code() { # $1 = path → prints HTTP status (empty on transport error)
  curl -sS -o /dev/null -w '%{http_code}' --cacert "$CA_CERT" \
    --resolve "$HOST:443:192.168.1.215" --max-time 15 "$APP_URL$1" 2>/dev/null || true
}
SIGNIN_CODE="$(tls_code /signin)"
PROJ_CODE="$(tls_code /api/factory/projects)"
if [[ "$SIGNIN_CODE" == "200" && "$PROJ_CODE" == "401" ]]; then
  log "verified: https://$HOST/signin -> 200 via Janet LAN Paperclip CA"
  log "verified: https://$HOST/api/factory/projects -> 401 signed-out (auth enforced)"
else
  die "HTTPS verification FAILED: /signin -> '${SIGNIN_CODE:-<transport error>}' (want 200), /api/factory/projects -> '${PROJ_CODE:-<transport error>}' (want 401 signed-out). nginx config IS live — inspect app/nginx logs and roll back via the pre-change-backup under $STATE_DIR if needed"
fi

log "DONE (deployment status: APPLIED). Login success is NOT asserted by this script — sign in via the browser to confirm. Trust the root CA on client devices only (see LOCAL-OPERATIONS.md); never distribute private keys."
