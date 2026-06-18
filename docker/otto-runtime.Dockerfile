#
# otto-runtime.Dockerfile — the Pilot daemon image, extended with the otto CLI.
#
# This image backs TWO compose services:
#   - otto-relay      : runs `otto start --attached` (the relay daemon, :8787)
#   - provider-daemon : runs pilot-daemon (no_skillinject); its supervisor execs
#                       our app (node bin/main.js), which spawns `otto mcp` as a
#                       CHILD in THIS container. So the otto CLI must be on PATH
#                       here, alongside the daemon + a Node 20+ runtime.
#
# Base is pilot-protocol/pilot:dev (the prebuilt no_skillinject image carrying
# pilot-daemon + pilotctl + wallet + rendezvous + Node 22). We add ONLY the otto
# npm CLI on top — no Go rebuild.
#
# keytar (otto's only native dep) is installed as a PREBUILT binary by
# prebuild-install (no compiler needed). We deliberately do NOT install libsecret:
# otto imports keytar lazily in a try/catch (client-secret-store.ts), so without
# libsecret the import fails GRACEFULLY and otto falls back to the
# OTTO_CONTROLLER_CLIENT_SECRET env var — exactly the headless path we use. This
# also makes `otto client register` print the secret (keychain-unavailable branch)
# so the entrypoint can capture it.
#
#   docker build -f docker/otto-runtime.Dockerfile -t pilot-protocol/otto-runtime:dev docker/
#
ARG PILOT_IMAGE=pilot-protocol/pilot:dev
FROM ${PILOT_IMAGE}

# Pin the otto CLI version. Bump in lockstep with extension-dist/ (same version).
ARG OTTO_VERSION=0.20.0

USER root
RUN npm install -g --no-audit --no-fund "@telepat/otto@${OTTO_VERSION}" \
 && otto --version \
 && node -e "const {createRequire}=require('module');const r=createRequire(require('child_process').execSync('readlink -f $(which otto)').toString().trim());r.resolve('@telepat/otto-relay/dist/index.js');console.log('otto-relay entrypoint resolvable: ok')"

# Back to the non-root container-local user from the base image.
USER pilot
WORKDIR /home/pilot

LABEL org.telepat.otto.runtime="pilot-daemon + otto CLI ${OTTO_VERSION}"
