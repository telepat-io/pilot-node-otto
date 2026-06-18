#!/usr/bin/env bash
#
# assemble-bundles.sh — build the SIGNED app bundle from the already-built wrapper
# image, into ./bundles/. Run scripts/build.sh (or build the images) first.
#
#   bundles/io.telepat.otto/  manifest.json + bin/{main,pilotServerWorker}.js + node_modules
#
# FREE node: there is NO wallet bundle (no payment). Only our app is signed.
#
# The manifest gets binary.sha256 pinned to its real binary, then signed with an
# ed25519 publisher key via `pilotctl appstore sign` (pure local crypto in a
# NETWORK-LESS throwaway container). The supervisor verifies sig + sha256.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLES="${ROOT}/bundles"
SECURE="${ROOT}/secure"
KEY="${SECURE}/publisher.key"
PILOT_IMAGE="${PILOT_IMAGE:-pilot-protocol/pilot:dev}"
WRAPPER_IMAGE="${WRAPPER_IMAGE:-pilot-protocol/otto-app:dev}"
APP_ID="io.telepat.otto"
log() { printf '\033[1;34m[assemble]\033[0m %s\n' "$*"; }

# pilotctl in a throwaway, network-less container that mounts the project.
pctl() { docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp -v "${ROOT}:${ROOT}" -w "${ROOT}" --entrypoint pilotctl "${PILOT_IMAGE}" "$@"; }

rm -rf "${BUNDLES}"; mkdir -p "${BUNDLES}/${APP_ID}" "${SECURE}"
chmod 700 "${SECURE}" || true

# ── app bundle: full /app tree from the wrapper image ────────────────────────
log "assembling ${APP_ID} bundle"
ACID="$(docker create "${WRAPPER_IMAGE}")"; trap 'docker rm -f "${ACID}" >/dev/null 2>&1 || true' EXIT
docker cp "${ACID}:/app/." "${BUNDLES}/${APP_ID}/"
docker rm -f "${ACID}" >/dev/null 2>&1 || true; trap - EXIT
chmod +x "${BUNDLES}/${APP_ID}/bin/main.js"

# ── publisher key (once) ─────────────────────────────────────────────────────
[ -f "${KEY}" ] || { log "gen publisher key"; pctl appstore gen-key "${KEY}"; }

# ── pin sha256 + sign ─────────────────────────────────────────────────────────
mf="${BUNDLES}/${APP_ID}/manifest.json"
binrel="$(grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]+"' "${mf}" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
sha="$(sha256sum "${BUNDLES}/${APP_ID}/${binrel}" | awk '{print $1}')"
log "  ${APP_ID}: pin ${binrel} sha256=${sha:0:16}…"
sed -i -E "s/(\"sha256\"[[:space:]]*:[[:space:]]*\")[0-9a-fA-F]{64}(\")/\1${sha}\2/" "${mf}"
log "  ${APP_ID}: sign + verify"
pctl appstore sign --key "${KEY}" "${mf}"
pctl appstore verify "${BUNDLES}/${APP_ID}"

log "bundle ready under ${BUNDLES} (signed). publisher key: ${KEY}"
