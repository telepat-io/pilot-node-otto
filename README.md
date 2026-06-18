# pilot-node-otto — `io.telepat.otto`

A containerized **Pilot Protocol app-store node** that exposes authenticated,
real-browser automation by wrapping the telepat.io **otto** agent. **Free** node:
no payment, no wallet. otto drives a real Chrome (no LLM tokens), so this node
involves **no model/LLM key**.

## What it is

A supervised app-store binary exposing one dataexchange capability with three
ops. It is a thin, honest bridge to otto's **stdio MCP** (`otto mcp`), which the
wrapper spawns as a child in the same container and drives as an authenticated
**controller** against the otto **relay**.

- **App id:** `io.telepat.otto`, `binary.runtime: "node"` (`app/manifest.json`).
- **Capability:** dataexchange JSON frames on overlay port 1001.
- **Role:** free provider — no payee/wallet, no quote/deliver.

## otto's real topology (and where the browser lives)

otto is three tiers:

1. **Relay** (`otto start`, port 8787, HTTP+WebSocket) — containerized here as the
   `otto-relay` service.
2. **Controller** (`otto mcp`) — spawned by this app inside the `provider-daemon`
   container; authenticates to the relay with a registered client.
3. **Node** = a real Chrome with the otto MV3 extension, paired to the relay —
   **NOT containerizable. There is no headless browser.**

So this repo containerizes everything **up to the browser**. The `extract` and
`screenshot` ops require a paired browser node; until you load the extension in
your own Chrome and pair it (see [`extension-dist/`](extension-dist/README.md)),
they return an honest error (`Missing targetNodeId …`). `status` works with no
browser and is the zero-dependency health check.

## Request protocol (peer ⇄ peer, dataexchange JSON frame on port 1001)

```
status     : { op:"status" }
              -> { op:"status", ok, relay_url, relay_reachable, relay_http_status,
                   controller_mcp_ok, browser_nodes:[…], browser_connected, note }
extract    : { op:"extract", url, format?, selector?, maxChars?, nodeId?, timeoutMs? }
              -> { op:"extract", ok, url, format, content?, title?, result }   # otto_extract_content
screenshot : { op:"screenshot", url, format?, nodeId?, timeoutMs? }
              -> { op:"screenshot", ok, url, image_base64?, format?, result }  # otto_screenshot
```

`format` for extract is one of `markdown` (default) `distilled_html` `clean_html`
`raw_html` `text`. Each request/reply is a single `DxType.JSON` frame; exact
shapes live in `app/src/types.ts`. The raw otto tool result is always passed
through under `result` so nothing is silently dropped.

## Build (inside Docker)

From a clean clone, one command builds **everything** — no external prerequisites:

```sh
scripts/build-all.sh
```

It produces, all inside `docker/*.Dockerfile`:

- `pilot-protocol/pilot:dev` — the Pilot daemon (`-tags no_skillinject`) + `pilotctl`
  + `wallet` + `rendezvous` + Node, from the pinned upstream sources.
- `build/libpilot.so` — the sdk-node FFI native lib (CGO c-shared, no_skillinject).
- `pilot-protocol/otto-runtime:dev` — `pilot:dev` + the `otto` CLI
  (`@telepat/otto@0.20.0`). Backs both the relay and the provider daemon.
- `pilot-protocol/otto-app:dev` — this app's bundle (tsup `bin/` + prod
  `node_modules` incl. `@modelcontextprotocol/sdk`).
- `bundles/io.telepat.otto/` — the signed, sha256-pinned app bundle.

The two **base** artifacts (`pilot:dev` + `libpilot.so`) are built **only if
absent** — they are slow (**~several minutes** the first time: the from-scratch Go
builds clone the pinned upstream pilotprotocol monorepo plus ~15 sibling org repos,
see `docker/upstream-pins.txt`). Subsequent runs reuse them in seconds. Force a
rebuild with `docker rmi pilot-protocol/pilot:dev && rm -f build/libpilot.so`.
Override the monorepo pin for development with `PILOT_REF=<ref> scripts/build-all.sh`.

> `scripts/build.sh` is the **fast path** when the two base artifacts already
> exist — it builds just the otto images + bundle and errors (pointing here) if a
> base artifact is missing. Upstream refs are pinned to exact SHAs in
> `docker/{pilot,libpilot,pilotctl}.Dockerfile` + `docker/upstream-pins.txt`.

> The otto CLI's only native dependency is `keytar`, installed as a prebuilt
> binary (no compiler). We deliberately omit `libsecret` so keytar's lazy import
> fails gracefully and otto uses the `OTTO_CONTROLLER_CLIENT_SECRET` env var —
> the headless credential path.

## Containers (dev vs prod)

| Service | Image | Dev (`compose.smoke.yaml`) | Prod (`compose.yaml`) |
|---------|-------|:--:|:--:|
| `otto-relay` — the otto relay (:8787, published for pairing) | otto-runtime | ✓ | ✓ |
| `provider-daemon` — our node; supervises `io.telepat.otto`, spawns `otto mcp` | otto-runtime | ✓ | ✓ |
| `rendezvous` — local overlay control plane | pilot | ✓ | — |
| `caller-daemon` — a second node playing the buyer | pilot | ✓ | — |

**Prod = two containers** (`otto-relay` + `provider-daemon`): the node joins
Pilot's real overlay via `PILOT_REGISTRY`/`PILOT_BEACON`. **Dev adds** a local
`rendezvous` + a caller on an isolated bridge so the full round-trip runs offline.

## Controller bootstrap (automated, headless)

`scripts/provider-entrypoint.sh` provisions the controller before starting the
daemon — no browser, no keytar:

```sh
otto config --relay-url ws://otto-relay:8787          # writes ~/.otto/config.json
otto client register --name … --description …          # prints OTTO_CONTROLLER_CLIENT_SECRET (cs_…)
export OTTO_CONTROLLER_CLIENT_SECRET=<captured cs_…>
otto client login                                      # mints access/refresh tokens into config.json
```

The relay must allow non-localhost registration — set on the relay service:
`OTTO_ALLOW_REMOTE_CONTROLLER_REGISTRATION=1` and (prod) a strong
`OTTO_TOKEN_SECRET` (the relay code default is `dev-only-change-me`). The exported
secret + `OTTO_RELAY_HTTP_URL` are inherited by the daemon, the supervised app,
and the app's `otto mcp` child (which reads the same `~/.otto/config.json`).

> Do **not** set `OTTO_CONTROLLER_REGISTRATION_SECRET` on the relay with this
> automated flow — the shipped `otto client register` does not send a
> registration secret, so it would reject the bootstrap.

## Smoke test (local network, no browser)

`compose.smoke.yaml` proves everything up to the browser:

```sh
scripts/build-all.sh
docker compose -f compose.smoke.yaml up -d
scripts/smoke-status.sh
docker compose -f compose.smoke.yaml down -v
```

`smoke-status.sh` asserts relay health, provider readiness, controller
register+login, and an `{op:"status"}` round-trip returning:

```json
{ "op":"status", "ok":true, "relay_url":"http://otto-relay:8787",
  "relay_reachable":true, "relay_http_status":200, "controller_mcp_ok":true,
  "browser_nodes":[], "browser_connected":false,
  "note":"relay reachable; NO browser node paired — …" }
```

`browser_connected:false` is honest: no browser is paired in the smoke. Sending
`{op:"extract"|"screenshot"}` with no browser returns
`ok:false, error:"Missing targetNodeId …"`.

## Load + pair the extension (the browser node)

The browser leg is **your Chrome**. Build artifact + full instructions are in
[`extension-dist/`](extension-dist/README.md): load `extension-dist/chrome-mv3/`
unpacked at `chrome://extensions`, set the relay URL `ws://127.0.0.1:8787`,
connect to get a pairing code, then approve it from the controller:

```sh
docker compose exec provider-daemon otto authcode      # list pending codes
docker compose exec provider-daemon otto pair 123-456  # approve
```

then **Grant** the controller access in the extension popup (ACL). After that,
`status` shows `browser_connected:true` and `extract`/`screenshot` run against
your real browser.

## Run in production

```sh
scripts/build-all.sh
cp .env.example .env        # set OTTO_TOKEN_SECRET (required); PILOT_REGISTRY/BEACON
docker compose up -d
docker compose logs -f provider-daemon
```

## Layout

```
.
├── README.md
├── LICENSE                 # Apache-2.0
├── compose.yaml            # production (otto-relay + provider-daemon)
├── compose.smoke.yaml      # isolated local regression test
├── .env.example
├── docker/                 # Dockerfiles (compiled inside Docker; upstream pinned)
│   ├── pilot.Dockerfile        # daemon(no_skillinject)+pilotctl+wallet+rendezvous
│   ├── libpilot.Dockerfile     # the sdk-node FFI native lib (CGO c-shared)
│   ├── pilotctl.Dockerfile     # pilotctl-only (release verification)
│   ├── otto-runtime.Dockerfile # pilot:dev + the otto CLI
│   ├── wrapper.Dockerfile      # this app's bundle (tsup + prod node_modules)
│   ├── upstream-pins.txt       # pinned SHAs for the upstream sibling repos
│   └── patches/                # libpilot-stubs.go (build-time //export stubs)
├── app/                    # the Node app (@telepat/otto-app)
│   ├── manifest.json       # app-store manifest (sha256/sig pinned at assemble time)
│   └── src/                # wrapper, capability server, otto stdio-MCP client, …
├── scripts/                # build-all, build, assemble-bundles, provider-entrypoint, smoke-status, dx-client
├── extension-dist/         # built MV3 extension + load/pair guide
└── build/libpilot.so       # sdk-node FFI lib (regenerated by build-all.sh; gitignored)
```

## License

[Apache-2.0](./LICENSE).
