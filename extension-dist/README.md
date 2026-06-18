# Otto browser extension (MV3) — load & pair

This is the **otto browser node**: a Manifest V3 Chrome extension built from
`@telepat/otto-extension@0.20.0` (the telepat.io otto monorepo, `wxt build`). The
otto node — the thing that actually drives a real, authenticated browser — is
**your Chrome with this extension loaded**. There is no headless browser; the
`extract` and `screenshot` capabilities only work once a browser node is paired.

Artifacts here:

- `chrome-mv3/` — the **unpacked** extension (load this via "Load unpacked").
- `telepatotto-extension-0.20.0-chrome.zip` — the same build, zipped.

> Rebuild from source: in the otto monorepo, `npm ci` then
> `npm --workspace @telepat/otto-protocol run build && npm --workspace @telepat/otto-extension run build`
> → output at `extension/output/chrome-mv3/`. (The protocol package must be built
> first or wxt fails to resolve `@telepat/otto-protocol`.)

## Prerequisite: the relay must be reachable from your Chrome

The node connects to the **otto relay** over WebSocket. With this repo's compose,
the relay publishes `127.0.0.1:8787` on your host, so the relay URL is:

```
ws://127.0.0.1:8787
```

Confirm it's up first:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/api/pairing/pending   # expect 200
```

(For a remote relay, publish `OTTO_RELAY_BIND=0.0.0.0` and use `ws://<host>:8787`
— and put TLS in front of it; the pairing/token endpoints are unauthenticated to
the network.)

## 1. Load the unpacked extension

1. Open `chrome://extensions` in Chrome (or any Chromium browser).
2. Toggle **Developer mode** on (top-right).
3. Click **Load unpacked** and select the `chrome-mv3/` directory next to this
   README.
4. The **Otto Node** extension appears. Pin it for convenience.

## 2. Connect to the relay and get a pairing code

1. Click the Otto toolbar icon (or open the extension's **Options** page).
2. Enter the relay URL `ws://127.0.0.1:8787` and click **Connect**.
3. The extension auto-bootstraps a node id and requests pairing from the relay.
   It then displays a **pairing code** like `123-456` and a ready-to-copy
   `otto pair 123-456` command. Keep this popup open — it polls for approval.

## 3. Approve the pairing from the controller

The controller is the `otto mcp` process running inside the **provider-daemon**
container. Approve the pending code from there:

```sh
# list pending pairing codes (controller-authenticated)
docker compose exec provider-daemon otto authcode

# approve the code shown in the extension popup
docker compose exec provider-daemon otto pair 123-456
```

> Note: use the **CLI** `otto authcode` / `otto pair` (they call the relay's
> `/api/pairing/*` routes). The MCP `otto_pair`/`otto_authcode` tools target
> different routes and are not used here.

When approved, the extension popup flips to **paired/connected**.

## 4. Grant the controller access to this node (ACL)

Pairing connects the node; a separate per-controller **ACL grant** authorizes
*this* controller to send commands. In the extension popup, find the
**Controller Access** card and click **Grant** for the controller that just
paired (otherwise commands fail with `acl_missing_node_grant`).

## 5. Verify end to end

From a caller, send `{op:"status"}` to the node (see the repo README). With the
browser paired + granted you should now see:

```json
{ "op":"status", "ok":true, "relay_reachable":true,
  "controller_mcp_ok":true, "browser_connected":true, "browser_nodes":["node_…"] }
```

Then `{op:"extract","url":"https://example.com"}` and
`{op:"screenshot","url":"https://example.com"}` run against your real browser.
