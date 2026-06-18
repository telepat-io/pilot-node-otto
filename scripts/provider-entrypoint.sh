#!/usr/bin/env bash
#
# provider-entrypoint.sh — bring up the otto provider node inside its container.
#
# Two jobs, in order:
#   1. BOOTSTRAP the otto controller: point the CLI at the relay, register a
#      controller client, and log in to mint access/refresh tokens — fully
#      headless (no browser, no keytar). The creds land in ~/.otto/config.json
#      and OTTO_CONTROLLER_CLIENT_SECRET, which the supervised app's `otto mcp`
#      child (spawned in THIS container) reuses.
#   2. INSTALL the signed app bundle into the writable install root and exec the
#      pilot-daemon (-no-dataexchange so our app owns overlay port 1001). The
#      always-on supervisor scans the install root, verifies the manifest
#      signature + binary sha256, and supervises our app.
#
# Why COPY the bundle (vs `pilotctl appstore install`): the install path copies
# ONLY manifest.json + the single binary (appstore.go), DROPPING our Node app's
# node_modules + worker file. So we place the FULL signed bundle dir ourselves;
# the supervisor verifies + supervises it. The dir must be WRITABLE (named volume)
# because the supervisor writes app.sock / data.db / identity.json there.
#
# keytar is unavailable in this image (no libsecret, by design), so
# `otto client register` prints the secret in its keychain-unavailable branch and
# we capture it. We register a FRESH controller client on every boot — simple and
# restart-robust (a brand-new client always works even if the relay restarted and
# forgot older clients). The minor relay-side client clutter is cosmetic.
set -euo pipefail

HOME_DIR="${HOME:-/home/pilot}"
APPS_DIR="${HOME_DIR}/.pilot/apps"
SOCK="${PILOT_SOCKET:-/run/pilot/pilot.sock}"
RUN_DIR="$(dirname "${SOCK}")"
REGISTRY="${RENDEZVOUS_REGISTRY:-rendezvous:9000}"
BEACON="${RENDEZVOUS_BEACON:-rendezvous:9001}"
HOSTN="${HOSTNAME_PILOT:-otto-provider}"
IDENTITY="${IDENTITY_PATH:-/data/identity.json}"
LOGLEVEL="${LOG_LEVEL:-debug}"
APP_BUNDLE="${APP_BUNDLE:-/bundles/io.telepat.otto}"

# Otto relay endpoints (the relay runs in a sibling container).
OTTO_RELAY_WS_URL="${OTTO_RELAY_WS_URL:-ws://otto-relay:8787}"
export OTTO_RELAY_HTTP_URL="${OTTO_RELAY_HTTP_URL:-http://otto-relay:8787}"
CTRL_NAME="${OTTO_CONTROLLER_NAME:-otto-pilot-provider}"
CTRL_DESC="${OTTO_CONTROLLER_DESCRIPTION:-Containerized Pilot otto node controller}"

log() { printf '\033[1;36m[provider-entrypoint]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[provider-entrypoint:FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "${APPS_DIR}" "${RUN_DIR}" "$(dirname "${IDENTITY}")" "${HOME_DIR}/.otto"
[ -S "${SOCK}" ] && rm -f "${SOCK}" || true

# ── 1. controller bootstrap ──────────────────────────────────────────────────
# Wait for the relay HTTP to answer (cheapest unauthenticated 200 route).
log "waiting for otto relay at ${OTTO_RELAY_HTTP_URL}"
relay_ready() {
  node -e "require('http').get('${OTTO_RELAY_HTTP_URL}/api/pairing/pending',r=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1))" 2>/dev/null
}
ready=0
for _ in $(seq 1 60); do
  if relay_ready; then ready=1; break; fi
  sleep 1
done
[ "${ready}" = 1 ] || die "otto relay not reachable at ${OTTO_RELAY_HTTP_URL} after 60s"
log "otto relay reachable"

log "configuring controller relay URL"
otto config --relay-url "${OTTO_RELAY_WS_URL}" >&2

log "registering controller client (fresh, headless)"
redact() { sed -E 's/cs_[A-Za-z0-9_-]+/cs_***REDACTED***/g'; }
REG_OUT="$(otto client register --name "${CTRL_NAME}" --description "${CTRL_DESC}" 2>&1)" || {
  # If the relay outlived a previous provider, its controller NAME is still
  # registered → HTTP 409 controller_name_conflict. A provider restart must not
  # be fatal: retry with a unique name. (A new controller needs a fresh ACL grant
  # in the extension popup — persist /home/pilot/.otto to avoid that.)
  if printf '%s' "${REG_OUT}" | grep -q 'controller_name_conflict'; then
    CTRL_NAME="${CTRL_NAME}-$(date +%s)-${RANDOM}"
    log "controller name already on the relay; retrying with unique name ${CTRL_NAME}"
    REG_OUT="$(otto client register --name "${CTRL_NAME}" --description "${CTRL_DESC}" 2>&1)" \
      || die "otto client register (retry) failed:\n$(printf '%s' "${REG_OUT}" | redact)"
  else
    die "otto client register failed:\n$(printf '%s' "${REG_OUT}" | redact)"
  fi
}
# Log register output with the cleartext client secret REDACTED (never log cs_…).
printf '%s\n' "${REG_OUT}" | sed -E 's/cs_[A-Za-z0-9_-]+/cs_***REDACTED***/g' >&2

# Capture the client secret. With no keychain, register prints:
#   [otto] export OTTO_CONTROLLER_CLIENT_SECRET='cs_…'
SECRET="$(printf '%s' "${REG_OUT}" | grep -oE 'cs_[A-Za-z0-9_-]+' | head -1 || true)"
[ -n "${SECRET}" ] || die "could not capture controller client secret from register output (is keytar unexpectedly available?)"
export OTTO_CONTROLLER_CLIENT_SECRET="${SECRET}"
log "captured controller secret (${SECRET:0:6}…); logging in"

otto client login >&2 || die "otto client login failed"

# Sanity: confirm controller auth works against the relay (no browser node yet).
if otto status --nodes --json >/tmp/otto-status.json 2>/dev/null; then
  log "controller authenticated; relay status: $(tr -d '\n' </tmp/otto-status.json)"
else
  log "WARN: 'otto status --nodes' did not return cleanly (continuing; the app re-checks per request)"
fi

# ── 2. install the signed app bundle ─────────────────────────────────────────
REINSTALL="${PILOT_REINSTALL_APPS:-0}"
if [ -d "${APP_BUNDLE}" ] && [ -f "${APP_BUNDLE}/manifest.json" ]; then
  id="$(basename "${APP_BUNDLE}")"
  dest="${APPS_DIR}/${id}"
  if [ -f "${dest}/manifest.json" ] && [ "${REINSTALL}" != "1" ]; then
    log "keeping existing install ${id} (PILOT_REINSTALL_APPS=1 to refresh)"
  else
    log "installing bundle ${id} -> ${dest} (full copy, preserves node_modules)"
    rm -rf "${dest:?}"
    cp -a "${APP_BUNDLE}" "${dest}"
  fi
  binrel="$(grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]+"' "${dest}/manifest.json" | head -1 | sed -E 's/.*"path"[^"]*"([^"]+)".*/\1/')"
  [ -n "${binrel}" ] && chmod +x "${dest}/${binrel}" 2>/dev/null || true
else
  die "app bundle not found or missing manifest: ${APP_BUNDLE}"
fi

# ── 3. start the daemon (inherits OTTO_CONTROLLER_CLIENT_SECRET + OTTO_RELAY_HTTP_URL) ─
log "starting pilot-daemon (no_skillinject) hostname=${HOSTN} registry=${REGISTRY} beacon=${BEACON} socket=${SOCK}"
exec pilot-daemon \
  -registry "${REGISTRY}" \
  -beacon "${BEACON}" \
  -socket "${SOCK}" \
  -identity "${IDENTITY}" \
  -public \
  -trust-auto-approve \
  -hostname "${HOSTN}" \
  -no-dataexchange \
  -log-level "${LOGLEVEL}"
