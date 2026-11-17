#!/usr/bin/env node
// Keeps the profile's bundle list in step with its dependencies.
//
// A DS Bot update removes the bundle before installing the new one, so a crash in
// that window leaves the package in `dependencies` but gone from `bundles` — DSH
// then starts as a bare shell with every Bot still on the volume but no UI for
// them. DSH has no CLI verb that re-selects a bundle, so repair the manifest here.
// Only the profile's own list is rewritten; nothing else in the file changes.
//
// Exit codes: 0 the file already agreed, 3 it was rewritten, anything else means
// the profile is unreadable and the caller should stop rather than start DSH.
//
// This lives in its own file, not inline in a `node -e` in entry.sh: an apostrophe
// in a JS comment ends the shell's single-quoted string and truncates the script.

import fs from 'node:fs'

const file = process.argv[2]
if (!file) {
  process.stderr.write('bundle-repair: usage: bundle-repair.mjs <profile package.json>\n')
  process.exit(2)
}

const pkg = JSON.parse(fs.readFileSync(file, 'utf8'))
const bundles = pkg.dsh?.profile?.bundles
if (!Array.isArray(bundles)) process.exit(0)

const depends = pkg.dependencies?.['ds-bot'] !== undefined
const listed = bundles.includes('ds-bot')
if (!depends && !listed) process.exit(0)

if (depends && !listed) {
  // Last, the position the image template ships: DSH resolves bundles in order,
  // and the client entry of the plugin has to come after the shell.
  bundles.push('ds-bot')
  fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`)
  process.stdout.write('added')
  process.exit(3)
}

if (!depends && listed) {
  pkg.dsh.profile.bundles = bundles.filter((name) => name !== 'ds-bot')
  fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`)
  process.stdout.write('dropped')
  process.exit(3)
}

process.exit(0)
