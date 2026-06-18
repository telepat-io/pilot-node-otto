#
# wrapper.Dockerfile — builds the io.telepat.otto Node app bundle.
#
# WHAT THIS PRODUCES
#   A self-contained app directory at /app containing:
#     /app/bin/main.js                 the bundled wrapper entrypoint (tsup ESM)
#     /app/bin/pilotServerWorker.js    the blocking-FFI worker thread
#     /app/node_modules                RUNTIME deps only (pilotprotocol sdk-node
#                                       + its FFI, @modelcontextprotocol/sdk)
#     /app/manifest.json               the app-store manifest
#     /app/package.json                (declares "type":"module" so bin/main.js loads)
#
#   The supervisor execs `node <InstallRoot>/io.telepat.otto/bin/main.js` with the
#   six lifecycle flags. This image only BUILDS the bundle; it is not a service.
#
# ─────────────────────────────────────────────────────────────────────────────
# INTEGRATION (read before wiring compose)
# ─────────────────────────────────────────────────────────────────────────────
# The app binary is NOT its own container. The Pilot app-store supervisor execs
# it as a CHILD PROCESS inside the provider-daemon container. The wrapper in turn
# spawns `otto mcp` (stdio MCP) as a child of ITSELF — so the provider-daemon
# image MUST also carry the `otto` CLI + a Node 20+ runtime on PATH. That image is
# docker/otto-runtime.Dockerfile (FROM pilot-protocol/pilot:dev + the otto CLI),
# and the app bundle this image produces is copied/mounted into the install root
# by scripts/provider-entrypoint.sh.
#
# Build context MUST be the repo root (so `app/` is reachable):
#   docker build -f docker/wrapper.Dockerfile -t otto-wrapper .
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: build — install ALL deps, typecheck, bundle with tsup ───────────
FROM node:22-bookworm-slim AS build
WORKDIR /app

# Copy manifests first for layer-cached dependency install.
COPY app/package.json app/package-lock.json app/tsconfig.json app/tsup.config.ts ./

# Full install (incl. devDeps) via `npm ci` against the committed lockfile so the
# dependency tree (and the release tarball sha) is reproducible. `pilotprotocol`
# ships a prebuilt FFI binding (PilotConnect) so no compiler is required.
RUN npm ci --no-audit --no-fund

# Bring in the TypeScript sources and the manifest.
COPY app/src ./src
COPY app/manifest.json ./manifest.json

# Typecheck (tsc --noEmit) then bundle src/main.ts -> bin/main.js (ESM, node20).
RUN npm run typecheck \
 && npm run build \
 && test -f bin/main.js \
 && test -f bin/pilotServerWorker.js

# ── Stage 2: prune — runtime-only node_modules for a slim, portable bundle ───
FROM node:22-bookworm-slim AS prune
WORKDIR /app
COPY app/package.json ./package.json
COPY app/package-lock.json ./package-lock.json
RUN npm ci --omit=dev --no-audit --no-fund

# ── Stage 3: bundle — the artifact the provider-daemon image carries ─────────
FROM node:22-bookworm-slim AS bundle
WORKDIR /app

COPY --from=build  /app/bin            ./bin
COPY --from=build  /app/manifest.json  ./manifest.json
COPY --from=build  /app/package.json   ./package.json
COPY --from=prune  /app/node_modules   ./node_modules

LABEL org.telepat.otto.bundle="/app" \
      org.telepat.otto.entrypoint="/app/bin/main.js" \
      org.telepat.otto.integration="copy /app into the install root; supervisor execs 'node /app/bin/main.js'; wrapper spawns 'otto mcp'"

# Build-artifact carrier, not a service. A no-op default explains the contract.
CMD ["node", "-e", "console.error('otto app bundle: not a standalone service. Copy /app into the provider-daemon install root; the app-store supervisor execs `node /app/bin/main.js`, which spawns `otto mcp`. See docker/wrapper.Dockerfile header.'); process.exit(1)"]
