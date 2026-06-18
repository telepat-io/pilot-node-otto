#!/usr/bin/env bash
#
# build.sh — build every image and the signed bundle for the io.telepat.otto node.
# Run this, then `docker compose -f compose.smoke.yaml up -d`, then
# scripts/smoke-status.sh.
#
# Nothing here RUNS any Pilot service on the host — every build happens inside a
# Dockerfile; the only host actions are `docker build` and pure-crypto `pilotctl`
# subcommands in throwaway, network-less containers (assemble-bundles).
#
# REQUIRES the two shared base artifacts to already exist (it does NOT build them):
#   pilot-protocol/pilot:dev   (daemon no_skillinject + pilotctl + rendezvous + node)
#   build/libpilot.so          (sdk-node FFI native lib)
# For a clean clone, run scripts/build-all.sh instead — it produces both base
# artifacts (from docker/{pilot,libpilot}.Dockerfile) IF ABSENT, then runs this.
#
# Images produced here:
#   pilot-protocol/otto-runtime:dev  pilot:dev + the otto CLI (relay + provider image)
#   pilot-protocol/otto-app:dev      our Node wrapper bundle (bin + node_modules)
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"   # this host has no buildx
log() { printf '\033[1;32m[build]\033[0m %s\n' "$*"; }

# Preconditions: the shared base artifacts must be present (run build-all.sh to
# produce them from a clean clone).
docker image inspect pilot-protocol/pilot:dev >/dev/null 2>&1 \
  || { echo "ERROR: pilot-protocol/pilot:dev not found. Run scripts/build-all.sh (it builds the base images from docker/pilot.Dockerfile), then re-run." >&2; exit 1; }
[ -f build/libpilot.so ] \
  || { echo "ERROR: build/libpilot.so missing. Run scripts/build-all.sh (it builds it from docker/libpilot.Dockerfile)." >&2; exit 1; }

log "1/3 otto-runtime image (pilot:dev + otto CLI)"
docker build -f docker/otto-runtime.Dockerfile -t pilot-protocol/otto-runtime:dev docker/

log "2/3 otto-app wrapper image (typecheck + tsup bundle, prod node_modules)"
docker build -f docker/wrapper.Dockerfile -t pilot-protocol/otto-app:dev .

log "3/3 assemble + sign bundle"
bash scripts/assemble-bundles.sh

log "DONE. Next (smoke test):"
log "  docker compose -f compose.smoke.yaml up -d"
log "  scripts/smoke-status.sh        # caller -> provider {op:status} round-trip"
