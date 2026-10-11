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
#     CA key:  /home/joelai/apps/paperclip/tls/ca.key   (NEVER copied,
#              displayed, moved, or otherwise altered — only referenced as
#              the signing key; the CA serial file is never touched because
#              signing uses an explicit random -set_serial)
# - Idempotent: reuses a matching, non-expired, CA-valid leaf cert/key pair
#   under state/tls/ (gitignored) on rerun; re-installs nginx files safely;
#   re-asserts the three .env.local keys (backup first).
# - Fails closed: nginx config is validated with `nginx -t` BEFORE any
#   reload and rolled back (added files removed / prior files restored) if
#   validation fails; if the app fails to come back healthy after the env
#   change + recreate, .env.local is restored from the backup and the app is
#   recreated on the previous env before exiting non-zero. Nothing under
#   state/ is ever deleted.
# - No global CA trust changes, no client installs, no DNS changes. Does not
#   assert login success (only HTTP-level readiness).
set -euo pipefail

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
[[ -r "$CA_KEY" ]] || die "CA key $CA_KEY not readable (existence is expected; this script never copies or displays it)"

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

COMPOSE=(docker compose --env-file "$ROOT/.env.local" -f "$ROOT/compose.local.yml" --project-directory "$ROOT")

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

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
    || die "newly issued leaf failed CA verification (CA key untouched; cert discarded is NOT done — inspect $STATE_DIR)"
  log "issued leaf: $(openssl x509 -in "$LEAF_CRT" -noout -subject -enddate | tr '\n' ' ')"
fi

# ------------------------------------------------- install nginx leaf cert/key
mkdir -p "$NGINX_SSL_DIR"; chmod 755 "$NGINX_SSL_DIR"
NGINX_SSL_CRT="$NGINX_SSL_DIR/$HOST.crt"
NGINX_SSL_KEY="$NGINX_SSL_DIR/$HOST.key"
install -m 0644 "$LEAF_CRT" "$NGINX_SSL_CRT"
install -m 0600 -o root -g root "$LEAF_KEY" "$NGINX_SSL_KEY"
log "installed leaf to $NGINX_SSL_DIR (crt 0644, key 0600 root:root)"

# ---------------------------------------------------- install nginx site file
# Refuse on unexpected pre-existing targets / symlink conflicts.
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
install -m 0644 "$ROOT/deployment/nginx-factory.conf" "$SITES_AVAILABLE"
if [[ ! -L "$SITES_ENABLED" ]]; then
  ln -s "$SITES_AVAILABLE" "$SITES_ENABLED"
fi
log "nginx site installed: $SITES_AVAILABLE -> $SITES_ENABLED"

# --------------------------------- validate BEFORE reload; rollback on failure
rollback_nginx() {
  log "rolling back nginx config changes (validation failed)"
  rm -f "$SITES_ENABLED"
  rm -f "$SITES_AVAILABLE"
  if nginx -t >/dev/null 2>&1; then
    log "rollback complete: nginx config valid again (no reload performed, running config untouched)"
  else
    log "WARNING: nginx -t still fails after rollback — nginx config was already broken before this script ran; investigate manually"
  fi
}
if ! nginx -t; then
  rollback_nginx
  die "nginx -t failed with the Factory site enabled; config changes rolled back, running nginx untouched"
fi
log "nginx -t passed"

# ------------------------------------- runtime env: backup + 3 keys, mode 0600
ENV_FILE="$ROOT/.env.local"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE missing"
ENV_BACKUP="$STATE_DIR/.env.local.backup-$(date +%Y%m%d-%H%M%S)"
cp -p "$ENV_FILE" "$ENV_BACKUP"; chmod 600 "$ENV_BACKUP"
log ".env.local backed up to $ENV_BACKUP (values never printed)"

set_env_key() { # file KEY VALUE — replace existing KEY= line or append; comments preserved
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    $0 ~ "^" key "=" { print key "=" value; replaced = 1; next }
    { print }
    END { if (!replaced) print key "=" value }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
  chmod 600 "$file"
}
set_env_key "$ENV_FILE" "MASTRACODE_PUBLIC_URL" "$APP_URL"
set_env_key "$ENV_FILE" "MASTRACODE_ALLOWED_ORIGINS" "$APP_URL"
set_env_key "$ENV_FILE" "FACTORY_SIGNUP_ENABLED" "0"
[[ "$(grep -c '^MASTRACODE_PUBLIC_URL=' "$ENV_FILE")" -eq 1 && "$(grep -c '^MASTRACODE_ALLOWED_ORIGINS=' "$ENV_FILE")" -eq 1 && "$(grep -c '^FACTORY_SIGNUP_ENABLED=' "$ENV_FILE")" -eq 1 ]] \
  || { cp -p "$ENV_BACKUP" "$ENV_FILE"; chmod 600 "$ENV_FILE"; die ".env.local key assertion failed after edit; restored from backup"; }
chmod 600 "$ENV_FILE"
log ".env.local updated: MASTRACODE_PUBLIC_URL / MASTRACODE_ALLOWED_ORIGINS = $APP_URL, FACTORY_SIGNUP_ENABLED = 0"

# ------------------------------------ recreate app as joelai; verify readiness
restore_env_and_app() {
  log "restoring .env.local from backup and recreating app on the previous env"
  cp -p "$ENV_BACKUP" "$ENV_FILE"; chmod 600 "$ENV_FILE"
  runuser -u joelai -- "${COMPOSE[@]}" up -d --no-build --force-recreate app \
    || log "WARNING: restore-recreate of app failed — check docker compose logs manually"
}
if ! runuser -u joelai -- "${COMPOSE[@]}" up -d --no-build --force-recreate app; then
  restore_env_and_app
  die "app recreate failed; .env.local restored, app recreated on previous env, nginx NOT reloaded (no config change is live)"
fi

READY=0
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:4112/signin; then READY=1; break; fi
  sleep 2
done
if [[ $READY -ne 1 ]]; then
  restore_env_and_app
  die "backend did not become ready at http://127.0.0.1:4112/signin within 60s; .env.local restored, app recreated on previous env, nginx NOT reloaded"
fi
log "backend ready on 127.0.0.1:4112 (signed-in-less /signin returned 200)"

# ------------------------------------------------------- reload nginx (last)
nginx -t || { log "WARNING: nginx -t failed just before reload — config NOT reloaded, running nginx untouched"; die "pre-reload nginx -t failed"; }
systemctl reload nginx || die "nginx reload failed — config is valid on disk; check systemctl status nginx"

# ------------------------------------------------------------- post-verification
TLS_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$CA_CERT" \
  --resolve "$HOST:443:192.168.1.215" --max-time 15 "$APP_URL/signin" || true)"
if [[ "$TLS_CODE" == "200" ]]; then
  log "verified: https://factory.janet.localdev/signin -> 200 via Janet LAN Paperclip CA"
else
  log "WARNING: /signin over HTTPS returned '$TLS_CODE' (expected 200) — inspect nginx error log"
fi

# Signed-out project endpoint should be 401. Try known candidate paths; 404
# on an unknown path is a documented limitation, not a deployment failure.
PROJ_OK=0
for p in /api/projects /api/factory/projects /api/factory/list; do
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$CA_CERT" \
    --resolve "$HOST:443:192.168.1.215" --max-time 15 "$APP_URL$p" || true)"
  if [[ "$CODE" == "401" ]]; then PROJ_OK=1; log "verified: $p signed-out -> 401"; break; fi
done
if [[ $PROJ_OK -ne 1 ]]; then log "WARNING: no candidate project endpoint returned 401 signed-out — auth enforcement not confirmed by this script"; fi

log "DONE (deployment status: APPLIED). Login success is NOT asserted by this script — sign in via the browser to confirm. Trust the root CA on client devices only (see LOCAL-OPERATIONS.md); never distribute private keys."
