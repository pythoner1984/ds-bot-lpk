#!/bin/sh
# Runs as root, once, under tini. Its only jobs are to seed the data volume and
# hand the process tree to uid 1000; it never comes back.
set -eu

APP_UID=1000
APP_GID=1000

log() { printf '[dsbot] %s\n' "$*"; }

# First install: the platform mounts an empty root-owned volume and DS Bot
# cannot bootstrap itself (no network at start, /usr/local is not writable).
if [ ! -d /data/profiles/web ]; then
  log "seeding /data from the image template"
  mkdir -p /data
  cp -a /opt/dsh-template/. /data/
fi

# One recursive pass is enough: from here on every process is uid 1000, so the
# files it writes are already owned correctly and a restart skips this.
if [ ! -f /data/.owner-fixed ]; then
  chown -R "$APP_UID:$APP_GID" /data 2>/dev/null || true
  : > /data/.owner-fixed
  chown "$APP_UID:$APP_GID" /data/.owner-fixed
fi

mkdir -p /workspace
if [ -z "$(ls -A /workspace 2>/dev/null)" ]; then
  chown "$APP_UID:$APP_GID" /workspace
fi

exec setpriv --reuid="$APP_UID" --regid="$APP_GID" --init-groups \
  /bin/sh /lzcapp/pkg/content/run.sh
