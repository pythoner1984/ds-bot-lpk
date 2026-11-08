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
RUN corepack enable \
 && npm config set registry "$NPM_REGISTRY" --global \
 && npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
      --allow-scripts=@deepseek-ai/dsh-subprocess-local,node-pty,koffi,@google/genai,protobufjs \
 && npm cache clean --force

# Prebuild the web profile with ds-bot already installed, so the first start
# needs no network and no writable /usr/local. The template is copied onto the
# data volume by entry.sh.
RUN mkdir -p /opt/dsh-template \
 && DSH_HOME=/opt/dsh-template dsh plugin --profile web add "ds-bot@${DS_BOT_VERSION}" \
 && test -d /opt/dsh-template/profiles/web \
 && chmod -R go-w /usr/local/lib/node_modules

COPY --from=edge /usr/bin/caddy /usr/local/bin/caddy
RUN caddy version && chmod 0755 /usr/local/bin/caddy

# Image-owned overlay, same content as upstream docker/docker.patch.yml: the
# container is the sandbox boundary, and /workspace is where bots work.
COPY lazycat.patch.yml /opt/ds-bot/lazycat.patch.yml

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
