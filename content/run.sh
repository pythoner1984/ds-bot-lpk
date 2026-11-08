#!/bin/sh
# Runs as uid 1000 under tini. It owns two listeners and one supervisor loop:
#   3080  Caddy — the only port the platform proxy reaches. It answers the
#         platform health probe, can demand a password, hands a first visit the
#         DSH launch token, and flushes SSE immediately.
#   3081  dsh --profile web, on loopback. DSH binds one concrete address and
#         refuses a wildcard; loopback also means Caddy is the only way in.
#
# The supervisor restarts dsh in place. Each dsh start mints a new launch token,
# so the token has to be re-read and Caddy reloaded every time — a token pinned
# at boot would turn the first crash-restart into a permanent 401.
set -u

PORT=3081
DOMAIN="${LAZYCAT_APP_DOMAIN:-}"
PUBLIC_URL="${DSBOT_PUBLIC_URL:-}"
ADMIN_FILE=/data/admin.txt
ACCESS_FILE=/data/access.txt
PASSWORD_FILE=/data/.admin-password
DSH_LOG=/data/dsh.log
DSH_LOG_PREV=/data/dsh.log.prev
CADDY_ADMIN=127.0.0.1:2019
CADDYFILE=/tmp/Caddyfile

TOKEN=""
CADDY_PID=""
DSH_PID=""

log() { printf '[dsbot] %s\n' "$*"; }

if [ -z "$PUBLIC_URL" ] && [ -n "$DOMAIN" ]; then
  PUBLIC_URL="https://${DOMAIN}/"
fi

# Two independent gates can sit in front of the UI:
#   * the platform's own account login, which every subdomain request passes
#     through first — that is the default and needs nothing from us;
#   * an optional HTTP basic-auth fence, off unless DSBOT_BASIC_AUTH=1.
# DSH's own launch token is handled separately, below.
BASIC_AUTH_BLOCK=""
ADMIN_USER="${DSBOT_ADMIN_USER:-admin}"
if [ "${DSBOT_BASIC_AUTH:-0}" = "1" ] || [ "${DSBOT_BASIC_AUTH:-0}" = "true" ]; then
  PASSWORD="${DSBOT_ADMIN_PASSWORD:-}"
  if [ -z "$PASSWORD" ] && [ -f "$PASSWORD_FILE" ]; then
    PASSWORD=$(cat "$PASSWORD_FILE")
  fi
  if [ -z "$PASSWORD" ]; then
    PASSWORD=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(15).toString("base64url"))')
    umask 077
    printf '%s' "$PASSWORD" > "$PASSWORD_FILE"
    log "generated a new admin password (see $ADMIN_FILE)"
  fi
  chmod 600 "$PASSWORD_FILE" 2>/dev/null || true
  HASH=$(caddy hash-password --plaintext "$PASSWORD" 2>/dev/null) || HASH=""
  if [ -z "$HASH" ]; then
    log "caddy hash-password failed; refusing to serve with a broken auth fence"
    exit 1
  fi
  BASIC_AUTH_BLOCK="		basic_auth {
			${ADMIN_USER} ${HASH}
		}"
fi

write_access() {
  umask 077
  {
    printf 'Open this once: %s\n\n' "$1"
    printf 'That link mints the browser cookie dsh needs. Tokens are per dsh\n'
    printf 'process: this file is rewritten whenever dsh restarts. If the app\n'
    printf 'answers "dsh web authentication required", open the URL below, or\n'
    printf 'open the app at /login which does the same thing.\n'
  } > "$ACCESS_FILE"
  chmod 600 "$ACCESS_FILE"
}

# Written on every start so it can never describe a configuration that is no
# longer running (an earlier version wrote it once and kept a stale password).
write_admin() {
  umask 077
  {
    printf 'DS Bot on this box\n\n'
    [ -n "$PUBLIC_URL" ] && printf 'URL:       %s\n' "$PUBLIC_URL"
    if [ -n "${PASSWORD:-}" ]; then
      printf 'Login:     HTTP Basic, user %s\n' "$ADMIN_USER"
      printf 'Password:  %s\n' "$PASSWORD"
    else
      printf 'Login:     the platform account for this box (no app password set)\n'
      printf '           set DSBOT_BASIC_AUTH=1 in the app settings to add one\n'
    fi
    printf 'Recover:   %s\n' "${PUBLIC_URL%/}/login (or $ACCESS_FILE)"
    printf 'Models:    Settings -> Model providers\n'
  } > "$ADMIN_FILE"
  chmod 600 "$ADMIN_FILE"
}

# The Caddyfile is regenerated, not edited: the token inside it changes with
# every dsh start. Nothing in here may use backticks or $ — this is an
# unquoted heredoc, so both would be expanded by the shell.
render_caddy() {
  if [ -n "$TOKEN" ]; then
    REDIRECT_BLOCK="		@needsToken {
			path / /index.html
			not header Cookie *dsh-auth-*
			not query token=*
		}
		redir @needsToken /?token=${TOKEN} 302
		@recover path /login
		redir @recover /?token=${TOKEN} 302"
  else
    REDIRECT_BLOCK="		@recover path /login
		respond @recover \"the app is still starting; retry in a few seconds\" 503"
  fi

  cat > "$CADDYFILE" <<EOF
{
	admin ${CADDY_ADMIN}
	auto_https off
}

:3080 {
	# The platform health probe runs without credentials; everything else goes
	# through the fences below. \`route\` keeps this order instead of Caddy's
	# directive ordering.
	route /healthz {
		respond "ok" 200
	}

	route {
${BASIC_AUTH_BLOCK}
${REDIRECT_BLOCK}
		encode gzip
		reverse_proxy 127.0.0.1:${PORT} {
			flush_interval -1
		}
	}
}
EOF
}

start_caddy() {
  if [ ! -s "$CADDYFILE" ]; then
    log "Caddyfile came out empty; refusing to start a half-configured proxy"
    exit 1
  fi
  if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    log "Caddyfile does not validate; refusing to start a half-configured proxy"
    caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1 | sed 's/^/[dsbot] /'
    exit 1
  fi
  caddy run --config "$CADDYFILE" --adapter caddyfile &
  CADDY_PID=$!
  log "caddy started (pid $CADDY_PID)"
}

reload_caddy() {
  if curl -sf -o /dev/null -X POST \
      -H 'Content-Type: text/caddyfile' \
      --data-binary "@$CADDYFILE" \
      "http://${CADDY_ADMIN}/load"; then
    log "caddy reloaded with the new token"
    return 0
  fi
  log "caddy reload failed; restarting the whole app"
  exit 1
}

start_dsh() {
  [ -f "$DSH_LOG" ] && mv -f "$DSH_LOG" "$DSH_LOG_PREV"
  : > "$DSH_LOG"
  if [ -n "$DOMAIN" ] && [ -n "$PUBLIC_URL" ]; then
    dsh --profile web \
      --patch /opt/ds-bot/lazycat.patch.yml \
      --no-open --host 127.0.0.1 --port "$PORT" \
      --public-url "$PUBLIC_URL" --trusted-host "$DOMAIN" >>"$DSH_LOG" 2>&1 &
  elif [ -n "$PUBLIC_URL" ]; then
    dsh --profile web \
      --patch /opt/ds-bot/lazycat.patch.yml \
      --no-open --host 127.0.0.1 --port "$PORT" \
      --public-url "$PUBLIC_URL" >>"$DSH_LOG" 2>&1 &
  else
    dsh --profile web \
      --patch /opt/ds-bot/lazycat.patch.yml \
      --no-open --host 127.0.0.1 --port "$PORT" >>"$DSH_LOG" 2>&1 &
  fi
  DSH_PID=$!
}

# dsh prints the token on one line once it is listening. Wait for it while the
# process is alive, and give up early when it dies instead of sitting out the
# whole timeout on every crash.
capture_token() {
  i=0
  while [ "$i" -lt 120 ]; do
    found=$(sed -n 's/.*[?&]token=\([A-Za-z0-9._~-]\{8,\}\).*/\1/p' "$DSH_LOG" 2>/dev/null | head -n 1)
    if [ -n "$found" ]; then
      printf '%s' "$found"
      return 0
    fi
    kill -0 "$DSH_PID" 2>/dev/null || return 1
    i=$((i + 1))
    sleep 1
  done
  return 1
}

shutdown() {
  [ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true
  [ -n "$CADDY_PID" ] && kill "$CADDY_PID" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

render_caddy
start_caddy
write_admin
log "starting dsh; a new launch token follows"

while :; do
  start_dsh
  if captured=$(capture_token); then
    if [ "$captured" != "$TOKEN" ]; then
      TOKEN=$captured
      log "captured a new launch token"
      if [ -n "$PUBLIC_URL" ]; then
        ACCESS_URL="${PUBLIC_URL%/}/?token=${TOKEN}"
      else
        ACCESS_URL="http://127.0.0.1:3080/?token=${TOKEN}"
      fi
      write_access "$ACCESS_URL"
      render_caddy
      reload_caddy
      log "one-time login link: $ACCESS_URL"
    fi
  else
    log "no launch token within 120s; see $DSH_LOG"
  fi

  # Wait for dsh to exit while still noticing a dead proxy.
  while :; do
    kill -0 "$DSH_PID" 2>/dev/null || break
    kill -0 "$CADDY_PID" 2>/dev/null || { log "caddy exited; taking the app down"; exit 1; }
    sleep 2
  done
  wait "$DSH_PID" 2>/dev/null
  rc=$?
  log "dsh exited ($rc); restarting in 3s"
  sleep 3
done
