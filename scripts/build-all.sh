#!/usr/bin/env bash
#
# build-all.sh — build EVERYTHING the io.telepat.otto node needs, from a clean
# clone, with no external prerequisites. Run this, then
# `docker compose -f compose.smoke.yaml up -d`, then scripts/smoke-status.sh.
#
# Nothing here RUNS any Pilot service on the host — every Go/Node build happens
# inside a Dockerfile; the only host actions are `docker build` and pure-crypto
# `pilotctl` subcommands in throwaway, network-less containers (assemble-bundles).
#
# This is the SELF-CONTAINED superset of scripts/build.sh. It first produces the
# two shared base artifacts that build.sh expects to already exist, then delegates
# to build.sh for the otto-specific images + signed bundle:
#
#   pilot-protocol/pilot:dev   daemon(no_skillinject)+pilotctl+wallet+rendezvous (+node)
#   build/libpilot.so          sdk-node FFI native lib (CGO c-shared, no_skillinject)
#   -- then build.sh --
#   pilot-protocol/otto-runtime:dev  pilot:dev + the otto CLI
#   pilot-protocol/otto-app:dev      our Node wrapper bundle
#   bundles/io.telepat.otto/         signed, sha256-pinned app bundle
#
# The two base artifacts are built ONLY IF ABSENT (they are large and slow:
# ~minutes for the from-scratch Go builds, which clone the pinned upstream
# pilotprotocol monorepo + ~15 sibling org repos — see docker/upstream-pins.txt).
# Force a rebuild by removing the image / file first:
#   docker rmi pilot-protocol/pilot:dev ; rm -f build/libpilot.so
#
# Upstream refs are pinned to exact SHAs (docker/{pilot,libpilot,pilotctl}.Dockerfile
# + docker/upstream-pins.txt); override the monorepo pin for development with
# PILOT_REF=<ref> scripts/build-all.sh.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"   # this host has no buildx; Dockerfiles avoid BuildKit features
log() { printf '\033[1;32m[build-all]\033[0m %s\n' "$*"; }

# Optional monorepo pin override, threaded into both Go image builds.
PILOT_REF_ARGS=()
[ -n "${PILOT_REF:-}" ] && PILOT_REF_ARGS=(--build-arg "PILOT_REF=${PILOT_REF}")

# ── 1. pilot image (Go binaries, no_skillinject) — ONLY IF ABSENT ────────────
if docker image inspect pilot-protocol/pilot:dev >/dev/null 2>&1; then
  log "1/3 pilot image present (pilot-protocol/pilot:dev) — skipping (docker rmi to force)"
else
  log "1/3 pilot image — from-scratch Go build (clones pinned upstream; minutes)"
  mkdir -p /tmp/pp-emptyctx
  docker build "${PILOT_REF_ARGS[@]}" -f docker/pilot.Dockerfile -t pilot-protocol/pilot:dev /tmp/pp-emptyctx
fi

# ── 2. libpilot.so (CGO c-shared, sibling-replace layout + patches) — IF ABSENT ─
if [ -f build/libpilot.so ]; then
  log "2/3 build/libpilot.so present ($(stat -c%s build/libpilot.so 2>/dev/null || echo ?) bytes) — skipping (rm to force)"
else
  log "2/3 libpilot.so — from-scratch CGO build (clones pinned upstream siblings; minutes)"
  docker build "${PILOT_REF_ARGS[@]}" -f docker/libpilot.Dockerfile -t pilot-protocol/libpilot:dev .
  mkdir -p build
  LCID="$(docker create pilot-protocol/libpilot:dev)"
  docker cp "${LCID}:/libpilot.so" build/libpilot.so
  docker rm -f "${LCID}" >/dev/null 2>&1 || true
  log "    -> build/libpilot.so ($(stat -c%s build/libpilot.so 2>/dev/null || echo ?) bytes)"
fi

# ── 3. otto-specific images + signed bundle (delegates to build.sh) ──────────
log "3/3 otto-runtime + otto-app images + signed bundle"
bash scripts/build.sh

log "DONE. Next (smoke test):"
log "  docker compose -f compose.smoke.yaml up -d"
log "  scripts/smoke-status.sh        # caller -> provider {op:status} round-trip"
