#!/bin/sh
# Runs as root, once, under tini. Its jobs: seed the data volume, bring the
# plugin inside an existing volume up to the version baked into this image, and
# hand the process tree to uid 1000. It never comes back.
set -eu

APP_UID=1000
APP_GID=1000
TEMPLATE=/opt/dsh-template
PROFILE=/data/profiles/web
PLUGIN=/data/.plugin-version

log() { printf '[dsbot] %s\n' "$*"; }

# First install: the platform mounts an empty root-owned volume and DS Bot
# cannot bootstrap itself (no network at start, /usr/local is not writable).
if [ ! -d "$PROFILE" ]; then
  log "seeding /data from the image template"
  mkdir -p /data
  cp -a "$TEMPLATE/." /data/
fi

# A newer image carries a newer ds-bot, but the profile — and therefore the
# plugin actually loaded — lives on the volume and would otherwise stay at
# whatever version was installed first. Copy the plugin in place instead of
# reinstalling: no network, and every other file in the profile (model
# providers, bot settings) is left alone.
wanted=$(cat "$TEMPLATE/.plugin-version" 2>/dev/null || true)
have=$(cat "$PLUGIN" 2>/dev/null || true)
if [ -n "$wanted" ] && [ "$wanted" != "$have" ]; then
  if [ -d "$TEMPLATE/profiles/web/node_modules/ds-bot" ]; then
    log "replacing the bundled plugin: ${have:-unknown} -> $wanted"
    rm -rf "$PROFILE/node_modules/ds-bot"
    cp -a "$TEMPLATE/profiles/web/node_modules/ds-bot" "$PROFILE/node_modules/ds-bot"
    node -e '
      const fs = require("node:fs")
      const file = process.argv[1]
      const pkg = JSON.parse(fs.readFileSync(file, "utf8"))
      pkg.dependencies = { ...pkg.dependencies, "ds-bot": process.argv[2] }
      fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`)
    ' "$PROFILE/package.json" "$wanted"
    chown -R -h "$APP_UID:$APP_GID" "$PROFILE/node_modules/ds-bot"
    chown "$APP_UID:$APP_GID" "$PROFILE/package.json"
    printf '%s' "$wanted" > "$PLUGIN"
    chown "$APP_UID:$APP_GID" "$PLUGIN"
  else
    log "template has no ds-bot to install; leaving the volume alone"
  fi
fi

# One recursive pass is enough: from here on every process is uid 1000, so the
# files it writes are already owned correctly and a restart skips this.
# `-h` keeps a symlink pointing out of the volume from carrying this ownership
# change to its target; the volume is writable by the bots, so it cannot be
# trusted to contain only regular files. A failed pass is fatal on purpose: the
# server cannot read its own 0600 credentials afterwards, and crashing here
# says why instead of looping invisibly.
if [ ! -f /data/.owner-fixed ]; then
  log "taking ownership of /data"
  if ! chown -R -h "$APP_UID:$APP_GID" /data; then
    log "chown failed; the volume is not writable by uid $APP_UID"
    exit 1
  fi
  : > /data/.owner-fixed
  chown "$APP_UID:$APP_GID" /data/.owner-fixed
fi

mkdir -p /workspace
if [ -z "$(ls -A /workspace 2>/dev/null)" ]; then
  chown "$APP_UID:$APP_GID" /workspace
fi

exec setpriv --reuid="$APP_UID" --regid="$APP_GID" --init-groups \
  /bin/sh /lzcapp/pkg/content/run.sh
