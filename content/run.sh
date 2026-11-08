#!/bin/sh
# Runs as uid 1000, under tini. Two listeners:
#   3080  Caddy — the only one the platform proxy reaches. It adds the HTTP
#         basic-auth fence and flushes SSE immediately.
#   3081  dsh --profile web, on loopback. DSH binds one concrete address and
#         refuses a wildcard; keeping it on loopback also means the only path in
#         is the authenticated one above.
set -u

PORT=3081
DOMAIN="${LAZYCAT_APP_DOMAIN:-}"
PUBLIC_URL="${DSBOT_PUBLIC_URL:-}"
ADMIN_FILE=/data/admin.txt
PASSWORD_FILE=/data/.admin-password

log() { printf '[dsbot] %s\n' "$*"; }

if [ -z "$PUBLIC_URL" ] && [ -n "$DOMAIN" ]; then
  PUBLIC_URL="https://${DOMAIN}/"
fi

# DSH is a single-user tool: it trusts its Host (that is the browser-trust
# fence's job) but authenticates nobody. The platform publishes the subdomain to
# anyone who knows it, so the fence is ours to add.
ADMIN_USER="${DSBOT_ADMIN_USER:-admin}"
PASSWORD="${DSBOT_ADMIN_PASSWORD:-}"
if [ -z "$PASSWORD" ] && [ -f "$PASSWORD_FILE" ]; then
  PASSWORD=$(cat "$PASSWORD_FILE")
fi
if [ -z "$PASSWORD" ]; then
  PASSWORD=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(15).toString("base64url"))')
  umask 077
  printf '%s' "$PASSWORD" > "$PASSWORD_FILE"
  log "generated a new admin password; it is written to $ADMIN_FILE"
fi
chmod 600 "$PASSWORD_FILE" 2>/dev/null || true

HASH=$(caddy hash-password --plaintext "$PASSWORD" 2>/dev/null) || HASH=""
if [ -z "$HASH" ]; then
  log "caddy hash-password failed; refusing to serve an unauthenticated UI"
  exit 1
fi

cat > /tmp/Caddyfile <<EOF
{
	admin off
	auto_https off
}

:3080 {
	# The platform healthcheck runs without credentials; everything else needs
	# them. `route` keeps this order instead of Caddy's directive ordering.
	route /healthz {
		respond "ok" 200
	}

	route {
		basic_auth {
			${ADMIN_USER} ${HASH}
		}
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
    [ -n "$PUBLIC_URL" ] && printf 'URL:      %s\n' "$PUBLIC_URL"
    printf 'User:     %s\n' "$ADMIN_USER"
    printf 'Password: %s\n\n' "$PASSWORD"
    printf 'Change the password in /data/.admin-password (delete it to get a new one),\n'
    printf 'then restart the app. Model providers and API keys are set in the app:\n'
    printf 'Settings -> Model providers.\n'
  } > "$ADMIN_FILE"
  chmod 600 "$ADMIN_FILE"
fi

caddy run --config /tmp/Caddyfile --adapter caddyfile &
CADDY_PID=$!
trap 'kill "$CADDY_PID" 2>/dev/null || true' TERM INT

# dsh is the process that must survive; restart it here rather than letting the
# platform take the whole app down. `set +e` because a non-zero exit must log
# and retry — with `set -e` the subshell would just end.
(
  set +e
  while :; do
    if [ -n "$DOMAIN" ] && [ -n "$PUBLIC_URL" ]; then
      dsh --profile web \
        --patch /opt/ds-bot/lazycat.patch.yml \
        --no-open --host 127.0.0.1 --port "$PORT" \
        --public-url "$PUBLIC_URL" --trusted-host "$DOMAIN"
    elif [ -n "$PUBLIC_URL" ]; then
      dsh --profile web \
        --patch /opt/ds-bot/lazycat.patch.yml \
        --no-open --host 127.0.0.1 --port "$PORT" \
        --public-url "$PUBLIC_URL"
    else
      dsh --profile web \
        --patch /opt/ds-bot/lazycat.patch.yml \
        --no-open --host 127.0.0.1 --port "$PORT"
    fi
    rc=$?
    log "dsh exited ($rc); restarting in 3s"
    sleep 3
  done
) &

i=0
while [ "$i" -lt 90 ]; do
  if node -e "require('node:http').get('http://127.0.0.1:3080/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))" 2>/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 2
done

log "ready: ${PUBLIC_URL:-http://127.0.0.1:3080/}"
if [ -f "$ADMIN_FILE" ] && [ -n "${PUBLIC_URL:-}" ]; then
  sed 's/^/[dsbot] /' "$ADMIN_FILE"
fi

wait "$CADDY_PID"
