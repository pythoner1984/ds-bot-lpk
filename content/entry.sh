#!/bin/sh
# Runs as root, once, under tini. Its jobs: seed the data volume, bring the
# plugin inside an existing volume up to the version baked into this image, and
# hand the process tree to uid 1000. It never comes back.
set -eu

# The platform keeps no readable log for a running app: `lzc-cli app log` says
# "not yet realized" and `project log` refuses once the service is down, which is
# exactly when the container's stdout matters. Keep our own, on the volume, so a
# container that dies before dsh ever starts still leaves a trace. run.sh
# inherits these descriptors through exec, so this file is the whole boot.
if [ -f /data/boot.log ]; then
  mv -f /data/boot.log /data/boot.log.prev
fi
exec >>/data/boot.log 2>&1
echo "[boot] $(date -u +%FT%TZ) container start"

APP_UID=1000
APP_GID=1000
TEMPLATE=/opt/dsh-template
PROFILE=/data/profiles/web
PLUGIN=/data/.plugin-version
WROTE=0

log() { printf '[dsbot] %s\n' "$*"; }

# Seed the volume from the image template. The profile counts as present only
# with its plugin tree: a copy interrupted by a container restart leaves the
# small files behind and no node_modules, and starting dsh on that half-written
# profile crashes it for good. Copy beside the target and rename, so a restart
# can only ever see a whole profile.
seed_profile() {
  log "seeding the web profile from the image template"
  WROTE=1
  rm -rf "$PROFILE.tmp"
  mkdir -p "$(dirname "$PROFILE")"
  cp -a "$TEMPLATE/profiles/web" "$PROFILE.tmp"
  rm -rf "$PROFILE"
  mv "$PROFILE.tmp" "$PROFILE"
}

if [ ! -d "$PROFILE/node_modules/ds-bot" ] || [ ! -f "$PROFILE/package.json" ]; then
  seed_profile
fi

# Everything the template carries besides `profiles` (the plugin version marker)
# is missing only on a first install; `profiles` was handled above.
for entry in "$TEMPLATE"/* "$TEMPLATE"/.[!.]*; do
  [ -e "$entry" ] || continue
  name=$(basename "$entry")
  [ "$name" = "profiles" ] && continue
  [ -e "/data/$name" ] && continue
  cp -a "$entry" "/data/$name"
done

# A newer image carries a newer ds-bot, but the profile — and therefore the
# plugin actually loaded — lives on the volume and would otherwise stay at
# whatever version was installed first. Copy the plugin in place instead of
# reinstalling: no network, and every other file in the profile (model
# providers, bot settings) is left alone.
wanted=$(cat "$TEMPLATE/.plugin-version" 2>/dev/null || true)
have=$(cat "$PLUGIN" 2>/dev/null || true)
# Newer than the image, not merely different: DS Bot updates its own plugin
# through DSH's plugin manager without touching this marker, so a plain
# inequality would drag that update back to whatever the image shipped.
if [ -n "$wanted" ] && node -e '
  const [want, have] = process.argv.slice(1)
  const parse = (v) => v.replace(/^v/, "").split(/[-+]/)[0].split(".").map((n) => Number(n) || 0)
  const [a, b] = [parse(want), parse(have)]
  for (let i = 0; i < 3; i += 1) {
    if (a[i] !== b[i]) process.exit(a[i] > b[i] ? 0 : 1)
  }
  process.exit(1)
' "$wanted" "${have:-0.0.0}"; then
  if [ -d "$TEMPLATE/profiles/web/node_modules/ds-bot" ]; then
    log "replacing the bundled plugin: ${have:-unknown} -> $wanted"
    WROTE=1
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

# A DS Bot update removes the bundle before installing the new one, so a crash in
# that window leaves the package in `dependencies` but gone from `bundles`, and DSH
# then starts as a bare shell. bundle-repair.mjs owns the check; this only acts on
# its exit code: 3 means the file was rewritten.
ensure_bundle() {
  node /lzcapp/pkg/content/bundle-repair.mjs "$PROFILE/package.json" || bundle_rc=$?
  case "${bundle_rc:-0}" in
    0) ;;
    3) log "repaired the profile bundle list"; WROTE=1 ;;
    *) log "bundle repair failed"; exit 1 ;;
  esac
  bundle_rc=0
}
ensure_bundle

# The profile is the one tree dsh must read as uid 1000, and it is also the one
# a previous container may have seeded as root. Check the owner every start:
# the marker below only remembers the first-install pass, which is too coarse
# when the volume already had a half-seeded profile on it.
profile_owner=$(stat -c %u "$PROFILE/package.json" 2>/dev/null || echo "")
if [ -n "$profile_owner" ] && [ "$profile_owner" != "$APP_UID" ]; then
  log "taking ownership of the web profile (owned by uid $profile_owner)"
  if ! chown -R -h "$APP_UID:$APP_GID" "$PROFILE"; then
    log "chown failed; the profile is not readable by uid $APP_UID"
    exit 1
  fi
fi

# Everything this script writes is root-owned, and dsh runs as uid 1000, so the
# pass has to run again after a seed or a plugin swap — not only on the very
# first start. The marker alone would skip it and leave a profile dsh cannot
# read (EACCES on package.json) .
if [ "$WROTE" = 1 ] || [ ! -f /data/.owner-fixed ]; then
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
