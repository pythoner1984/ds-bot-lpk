#!/bin/sh
# Runs as uid 1000, under tini. Two listeners:
#   3080  Caddy — the only one the platform proxy reaches. It answers the health
#         probe, optionally demands a password, and flushes SSE immediately.
#   3081  dsh --profile web, on loopback. DSH binds one concrete address and
#         refuses a wildcard; loopback also means Caddy is the only way in.
set -u

PORT=3081
DOMAIN="${LAZYCAT_APP_DOMAIN:-}"
PUBLIC_URL="${DSBOT_PUBLIC_URL:-}"
ADMIN_FILE=/data/admin.txt
ACCESS_FILE=/data/access.txt
PASSWORD_FILE=/data/.admin-password
DSH_LOG=/data/dsh.log

log() { printf '[dsbot] %s\n' "$*"; }

if [ -z "$PUBLIC_URL" ] && [ -n "$DOMAIN" ]; then
  PUBLIC_URL="https://${DOMAIN}/"
fi

# Two independent gates can sit in front of the UI:
#   * the platform's own account login, which every subdomain request passes
#     through first — that is the default and needs nothing from us;
#   * an optional HTTP basic-auth fence, off unless DSBOT_BASIC_AUTH=1.
# DSH's own launch token is handled separately, below.
AUTH_ARGS=""
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
  ADMIN_USER_LINE="${ADMIN_USER} ${HASH}"
  BASIC_AUTH_BLOCK="		basic_auth {
			${ADMIN_USER_LINE}
		}"
fi

# dsh is the process that must survive; restart it here rather than letting the
# platform take the whole app down. `set +e` because a non-zero exit must log
# and retry — with `set -e` the subshell would just end.
(
  set +e
  while :; do
    : > "$DSH_LOG"
    if [ -n "$DOMAIN" ] && [ -n "$PUBLIC_URL" ]; then
      dsh --profile web \
        --patch /opt/ds-bot/lazycat.patch.yml \
        --no-open --host 127.0.0.1 --port "$PORT" \
        --public-url "$PUBLIC_URL" --trusted-host "$DOMAIN" >>"$DSH_LOG" 2>&1
    elif [ -n "$PUBLIC_URL" ]; then
      dsh --profile web \
        --patch /opt/ds-bot/lazycat.patch.yml \
        --no-open --host 127.0.0.1 --port "$PORT" \
        --public-url "$PUBLIC_URL" >>"$DSH_LOG" 2>&1
    else
      dsh --profile web \
        --patch /opt/ds-bot/lazycat.patch.yml \
        --no-open --host 127.0.0.1 --port "$PORT" >>"$DSH_LOG" 2>&1
    fi
    rc=$?
    log "dsh exited ($rc); restarting in 3s"
    sleep 3
  done
) &

# dsh mints a fresh launch token every time it starts and only a request that
# carries it can mint the browser session cookie. The token is therefore
# captured from the startup line and used twice: once to exchange the cookie
# automatically for the first visit, and once in access.txt, so a session that
# lost its cookie can be recovered without a terminal.
i=0
TOKEN=""
while [ "$i" -lt 150 ]; do
  TOKEN=$(sed -n 's/.*[?&]token=\([A-Za-z0-9._~-]\{8,\}\).*/\1/p' "$DSH_LOG" 2>/dev/null | head -n 1)
  [ -n "$TOKEN" ] && break
  i=$((i + 1))
  sleep 1
done

if [ -n "$TOKEN" ]; then
  log "captured the launch token from dsh"
  if [ -n "$PUBLIC_URL" ]; then
    ACCESS_URL="${PUBLIC_URL%/}/?token=${TOKEN}"
  else
    ACCESS_URL="http://127.0.0.1:3080/?token=${TOKEN}"
  fi
  umask 077
  {
    printf 'Open this once: %s\n\n' "$ACCESS_URL"
    printf 'That link mints the browser cookie dsh needs; it is spent on the first\n'
    printf 'visit and a new one is written on every app restart. If the app answers\n'
    printf '"dsh web authentication required", reopen the link below.\n'
  } > "$ACCESS_FILE"
  chmod 600 "$ACCESS_FILE"
else
  log "no launch token seen after 150s; the UI will ask for one (see $DSH_LOG)"
  ACCESS_URL=""
fi

# DSBOT_STRICT_AUTH=1 keeps upstream's behaviour: the token link is the only way
# in. The default trades that for the platform's own login — one less secret to
# read out of a container on a box whose UI is already behind an account.
if [ "${DSBOT_STRICT_AUTH:-0}" = "1" ]; then
  REDIRECT_BLOCK=""
else
  if [ -n "${TOKEN:-}" ]; then
    REDIRECT_BLOCK="	@needsToken {
		path /
		not header Cookie *dsh-auth-*
		not query token=*
	}
	redir @needsToken /?token=${TOKEN} 302"
  else
    REDIRECT_BLOCK=""
  fi
fi

cat > /tmp/Caddyfile <<EOF
{
	admin off
	auto_https off
}

:3080 {
	# The platform health probe runs without credentials; everything else goes
	# through the fences below. `route` keeps this order instead of Caddy's
	# directive ordering.
	route /healthz {
		respond "ok" 200
	}

	route {
${BASIC_AUTH_BLOCK}
${REDIRECT_BLOCK}
		encode zstd gzip
		reverse_proxy 127.0.0.1:${PORT} {
			flush_interval -1
		}
	}
}
EOF

if [ ! -f "$ADMIN_FILE" ]; then
  umask 077
  {
    printf 'DS Bot on this box\n\n'
    [ -n "$PUBLIC_URL" ] && printf 'URL:       %s\n' "$PUBLIC_URL"
    if [ -n "${PASSWORD:-}" ]; then
      printf 'User:      %s\n' "$ADMIN_USER"
      printf 'Password:  %s\n' "$PASSWORD"
    else
      printf 'Login:     the platform account for this box (no app password set)\n'
      printf '           set DSBOT_BASIC_AUTH=1 in the app settings to add one\n'
    fi
    printf 'Fallback:  %s\n\n' "$ACCESS_FILE"
    printf 'Model providers and API keys are set in the app: Settings -> Model providers.\n'
  } > "$ADMIN_FILE"
  chmod 600 "$ADMIN_FILE"
fi

if [ ! -s /tmp/Caddyfile ]; then
  log "Caddyfile came out empty; refusing to start a half-configured proxy"
  exit 1
fi
if ! caddy validate --config /tmp/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  log "Caddyfile does not validate; refusing to start a half-configured proxy"
  caddy validate --config /tmp/Caddyfile --adapter caddyfile 2>&1 | sed 's/^/[dsbot] /'
  exit 1
fi

caddy run --config /tmp/Caddyfile --adapter caddyfile &
CADDY_PID=$!
trap 'kill "$CADDY_PID" 2>/dev/null || true' TERM INT

i=0
while [ "$i" -lt 90 ]; do
  if node -e "require('node:http').get('http://127.0.0.1:3080/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))" 2>/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 2
done

log "ready: ${PUBLIC_URL:-http://127.0.0.1:3080/}"
if [ -n "${ACCESS_URL:-}" ]; then
  log "one-time login link: $ACCESS_URL"
fi
if [ -f "$ADMIN_FILE" ]; then
  sed 's/^/[dsbot] /' "$ADMIN_FILE"
fi

wait "$CADDY_PID"
