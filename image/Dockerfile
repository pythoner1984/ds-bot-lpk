# DS Bot as a Lazycat app (lazycat.cloud / 微服).
#
# This repository packages upstream DS Bot unchanged: it installs the published
# `ds-bot` plugin from npm into a prebuilt DSH home, and runs `dsh --profile web`
# behind Caddy. Nothing in DS Bot's own source is patched, so upstream releases
# can be picked up by bumping the two ARGs below.
#
# Why npm and not upstream's docker/Dockerfile: that one builds the plugin from
# a source checkout and pulls node:24-bookworm-slim from docker.io. The box
# cannot reach docker.io or ghcr.io, but it can reach npm and DaoCloud's
# docker.io mirror, so every FROM below goes through the mirror and the plugin
# comes from the registry.
ARG NODE_IMAGE=docker.m.daocloud.io/library/node:24-bookworm
ARG DSH_VERSION=0.2.2-rc.1
ARG DS_BOT_VERSION=0.3.1
ARG NPM_REGISTRY=https://registry.npmjs.org/

# Same binary as the OMB package and upstream's deploy/local stack, so the
# reverse-proxy behaviour (SSE flushing, basic auth) is a known quantity.
FROM docker.m.daocloud.io/library/caddy:2.10.2 AS edge

FROM ${NODE_IMAGE}
ARG DSH_VERSION
ARG DS_BOT_VERSION
ARG NPM_REGISTRY

USER root

# tini is PID 1: bots leave shell children behind and the platform gives a
# service no init of its own. bash/git/curl are what bots expect to find; the
# rest is what DS Bot's tool cells reach for.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash git curl ca-certificates tini \
      jq ripgrep unzip zip less procps python3 \
 && rm -rf /var/lib/apt/lists/*

# --allow-scripts is the list upstream's docker/Dockerfile installs with; the
# native modules in it fail to build without it.
# pnpm is pinned because `dsh plugin` shells out to it at runtime: a version
# resolved by corepack at build time and another one resolved at run time make
# pnpm refuse the profile's existing node_modules.
RUN npm config set registry "$NPM_REGISTRY" --global \
 && npm install -g pnpm@12.18.0 --allow-scripts=pnpm \
 && npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
      --allow-scripts=@deepseek-ai/dsh-subprocess-local,node-pty,koffi,@google/genai,protobufjs \
 && npm cache clean --force

# Prebuild the web profile with ds-bot already installed, so the first start
# needs no network and no writable /usr/local. The template is copied onto the
# data volume by entry.sh, and `.plugin-version` is what lets a later image
# replace the plugin inside an existing volume — a directory check alone would
# pass for whatever the volume happened to hold.
#
# HOME is /data here on purpose: pnpm records the store it linked a
# node_modules from inside node_modules/.modules.yaml, and refuses to touch that
# node_modules from any other store. Runtime runs as uid 1000 with HOME=/data,
# so building under the same HOME is what makes DS Bot's own in-app update
# (`dsh plugin add`) work later. The store itself is dropped from the image at
# the end of this step; only the recorded path has to agree.
RUN mkdir -p /opt/dsh-template /data \
 && HOME=/data DSH_HOME=/opt/dsh-template dsh plugin --profile web add "ds-bot@${DS_BOT_VERSION}" \
 && node -e 'const want=process.argv[1];const got=require("/opt/dsh-template/profiles/web/package.json").dependencies["ds-bot"];if(got!==want){console.error(`profile has ds-bot ${got}, expected ${want}`);process.exit(1)}' "${DS_BOT_VERSION}" \
 && printf '%s' "${DS_BOT_VERSION}" > /opt/dsh-template/.plugin-version \
 && chmod -R go-w /usr/local/lib/node_modules \
 && rm -rf /data/.local/share/pnpm/store

COPY --from=edge /usr/bin/caddy /usr/local/bin/caddy
RUN caddy version && chmod 0755 /usr/local/bin/caddy

# Image-owned overlay, same content as upstream docker/docker.patch.yml: the
# container is the sandbox boundary, and /workspace is where bots work.
COPY lazycat.patch.yml /opt/ds-bot/lazycat.patch.yml

# Health means "the proxy answers and dsh is listening", not just "Caddy is up":
# a crash loop inside the restart supervisor must eventually surface here.
COPY healthcheck.mjs /opt/ds-bot/healthcheck.mjs

# The image starts as root only so entry.sh can seed and take ownership of the
# mounted volume; entry.sh then re-executes itself as uid 1000 through setpriv
# and never comes back. 1000 is node:24-bookworm's own `node` user — a second
# user at that id fails with "UID 1000 is not unique".
RUN mkdir -p /data /workspace \
 && chown 1000:1000 /data /workspace \
 && setpriv --help >/dev/null

ENV HOME=/data \
    DSH_HOME=/data

WORKDIR /workspace
EXPOSE 3080
