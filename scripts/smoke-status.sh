#!/usr/bin/env bash
#
# smoke-status.sh — VERIFIED check of everything UP TO the browser.
#
# Proves on the local test network, with NO browser node:
#   - relay healthy on :8787
#   - provider app ready (app.sock present) → wrapper spawned `otto mcp`
#   - the controller registered + logged in against the relay (provider logs)
#   - an {op:"status"} dataexchange round-trip caller → provider:1001 returns
#     relay_reachable:true, controller_mcp_ok:true, browser_connected:false
#     (HONEST: no browser paired yet — that leg is the operator's Chrome).
#
# Everything runs in containers; the host never executes Pilot/otto/Node.
#
# Prereq: scripts/build.sh then `docker compose -f compose.smoke.yaml up -d`.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; cd "${ROOT}"
export COMPOSE_FILE="${COMPOSE_FILE:-compose.smoke.yaml}"
PROJECT="${COMPOSE_PROJECT:-otto-smoke}"
NET="${PROJECT}_pilot-net"
CALLER_RUN_VOL="${PROJECT}_caller-run"

log() { printf '\033[1;36m[smoke-status]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[smoke-status:ok]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[smoke-status:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f build/libpilot.so ] || die "build/libpilot.so missing — run scripts/build.sh first"

wait_healthy() { # <service> <label>
  local name="${PROJECT}-$1-1" label="$2" st=""
  for _ in $(seq 1 60); do
    st="$(docker inspect -f '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo none)"
    [ "${st}" = healthy ] && { ok "${label} healthy"; return 0; }
    sleep 2
  done
  die "${label} (${name}) not healthy (status=${st:-none}); check 'docker compose logs $1'"
}
log "waiting for relay, provider app, and caller daemon to be healthy"
wait_healthy otto-relay      "otto relay"
wait_healthy provider-daemon "provider app"
wait_healthy caller-daemon   "caller daemon"

# Provider must have spawned otto mcp + authenticated the controller.
log "checking provider logs for controller bootstrap"
PLOGS="$(docker compose logs provider-daemon 2>&1)"
echo "${PLOGS}" | grep -q 'registering controller client' || die "provider did not register a controller client"
echo "${PLOGS}" | grep -qi 'otto.*login\|controller authenticated' || log "  (login confirmation line not found; relying on the status round-trip below)"
ok "provider bootstrapped controller"

# Provider overlay address (from its daemon log).
PADDR="$(echo "${PLOGS}" | grep -oE 'addr=0:[0-9.A-F]+' | tail -1 | cut -d= -f2)"
[ -n "${PADDR}" ] || die "could not determine provider overlay address from logs"
log "provider overlay address: ${PADDR}"

# dx <json> : one dataexchange round-trip caller -> provider:1001. Prints reply.
dx() {
  docker run --rm --network "${NET}" \
    -v "${CALLER_RUN_VOL}:/caller-run" \
    -v "${ROOT}/build/libpilot.so:/opt/libpilot.so:ro" \
    -v "${ROOT}/scripts:/app/scripts:ro" \
    -e PILOT_LIB_PATH=/opt/libpilot.so \
    --entrypoint node -w /app \
    pilot-protocol/otto-app:dev \
    /app/scripts/dx-client.mjs --socket /caller-run/pilot.sock --target "${PADDR}" --json "$1"
}

log "status: caller -> provider:1001 {op:status}"
REPLY="$(dx '{"op":"status"}')" || die "status round-trip failed (dx-client errored)"
echo "  reply: ${REPLY}"
echo "${REPLY}" | grep -q '"op":"status"'            || die "no status op in reply: ${REPLY}"
echo "${REPLY}" | grep -q '"relay_reachable":true'   || die "relay not reachable per status: ${REPLY}"
echo "${REPLY}" | grep -q '"controller_mcp_ok":true' || die "controller/MCP path not OK (otto mcp / auth failed): ${REPLY}"
echo "${REPLY}" | grep -q '"browser_connected":false' || die "expected NO browser node in smoke (got browser_connected:true?): ${REPLY}"
ok "status round-trip OK — relay reachable, controller+MCP working, no browser node (as expected)"

ok "PASS ✅  everything up to the browser works. The live extract/screenshot leg needs the operator's paired Chrome (see README)."
