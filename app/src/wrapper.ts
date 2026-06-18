/**
 * wrapper.ts — entrypoint orchestration for the io.telepat.otto app.
 *
 * FREE node (no payment): no wallet IPC, no quote/deliver, no dedupe. The app is
 * a thin, honest bridge from a Pilot dataexchange capability to the telepat.io
 * "otto" browser-automation agent, driven over otto's stdio MCP (`otto mcp`,
 * spawned as a child in THIS container by mcpStdioClient.ts).
 *
 * Lifecycle (cite: supervisor.go:752-808):
 *   1. Parse the six lifecycle flags (--addr --db --socket --identity
 *      --manifest --cap-state); tolerate unknown flags.
 *   2. Open the --socket unix listener (supervisor readiness signal).
 *   3. Start the dataexchange capability server on port 1001, handling:
 *        op:"status"     -> relay reachability + connected browser nodes
 *        op:"extract"    -> otto_extract_content {url, format}
 *        op:"screenshot" -> otto_screenshot {url, format}
 *
 * Topology reality (research of otto packages/cli + packages/relay):
 *   - The RELAY runs in a separate container (otto-relay:8787).
 *   - This app spawns the CONTROLLER (`otto mcp`) locally; it reaches the relay
 *     using creds in ~/.otto/config.json + OTTO_CONTROLLER_CLIENT_SECRET, both
 *     provisioned by scripts/provider-entrypoint.sh before the daemon starts.
 *   - The NODE is a real Chrome with the otto extension, paired by the operator.
 *     There is NO headless browser — extract/screenshot need a paired browser.
 *     When none is paired, otto returns an honest error ("Missing targetNodeId
 *     …") which we pass through verbatim.
 *
 * Env (inherited from the daemon):
 *   PILOT_SOCKET             daemon data-plane unix socket (default /tmp/pilot.sock)
 *   OTTO_RELAY_HTTP_URL      relay HTTP base for the status probe (default http://otto-relay:8787)
 *   OTTO_DEFAULT_TIMEOUT_MS  per-call otto tool timeout (default 60000)
 */

import * as path from 'node:path';
import type { LifecycleFlags, OttoRequest, OttoResponse, OttoMcpClient } from './types.js';
import { serveAppSocket } from './appSock.js';
import { startCapabilityServer } from './pilotServer.js';
import { getOttoMcpClient } from './mcpStdioClient.js';
import { log } from './log.js';

/** The capability/overlay port (1001 == dataexchange). */
const CAPABILITY_PORT = 1001;

/** Parse the six supervisor flags; ignore anything unrecognized. */
export function parseFlags(argv: string[]): LifecycleFlags {
  const map = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === undefined || !a.startsWith('--')) continue;
    const eq = a.indexOf('=');
    if (eq >= 0) {
      map.set(a.slice(2, eq), a.slice(eq + 1));
    } else {
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith('--')) {
        map.set(a.slice(2), next);
        i++;
      } else {
        map.set(a.slice(2), '');
      }
    }
  }
  const req = (k: string): string => {
    const v = map.get(k);
    if (v === undefined || v === '') throw new Error(`wrapper: missing required flag --${k}`);
    return v;
  };
  return {
    addr: req('addr'),
    db: req('db'),
    socket: req('socket'),
    identity: req('identity'),
    manifest: req('manifest'),
    capState: req('cap-state'),
  };
}

interface Config {
  daemonSocketPath: string;
  relayHttpUrl: string;
  defaultTimeoutMs: number;
}

function loadConfig(): Config {
  const relay = (process.env['OTTO_RELAY_HTTP_URL'] ?? 'http://otto-relay:8787').replace(/\/$/, '');
  return {
    daemonSocketPath: process.env['PILOT_SOCKET'] ?? '/tmp/pilot.sock',
    relayHttpUrl: relay,
    defaultTimeoutMs: Number.parseInt(process.env['OTTO_DEFAULT_TIMEOUT_MS'] ?? '60000', 10) || 60000,
  };
}

/** Probe the relay's cheapest unauthenticated 200 route to confirm reachability.
 *  The relay exposes no /health route; GET /api/pairing/pending returns 200 with
 *  {pending:[...]} (cite: relay http-routes/index.ts). */
async function probeRelay(relayHttpUrl: string): Promise<{ reachable: boolean; httpStatus?: number; error?: string }> {
  const url = `${relayHttpUrl}/api/pairing/pending`;
  try {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 4000);
    try {
      const res = await fetch(url, { signal: ac.signal });
      return { reachable: res.status < 500, httpStatus: res.status };
    } finally {
      clearTimeout(t);
    }
  } catch (err) {
    return { reachable: false, error: (err as Error).message };
  }
}

/** Pull a likely "content" string out of an otto extract envelope payload.
 *  Shape is node-defined (cite: cli/extract-content-handler.ts returns the raw
 *  node Envelope); we best-effort surface common fields and ALWAYS pass the raw
 *  result through so nothing is silently dropped. */
function surfaceExtract(result: unknown): { content?: string; title?: string } {
  const out: { content?: string; title?: string } = {};
  const r = result as { response?: { payload?: { data?: Record<string, unknown> } } } | undefined;
  const data = r?.response?.payload?.data;
  if (data && typeof data === 'object') {
    for (const key of ['markdown', 'content', 'text', 'html', 'distilledHtml', 'cleanHtml']) {
      const v = (data as Record<string, unknown>)[key];
      if (typeof v === 'string' && v.length > 0) {
        out.content = v;
        break;
      }
    }
    const title = (data as Record<string, unknown>)['title'];
    if (typeof title === 'string') out.title = title;
  }
  return out;
}

/** Pull base64 image bytes out of an otto screenshot result payload.
 *  The node returns base64 under data.contentBase64 + data.format
 *  (cite: cli/index.ts screenshot command reads payload.data.contentBase64). */
function surfaceScreenshot(result: unknown): { imageBase64?: string; format?: string } {
  const out: { imageBase64?: string; format?: string } = {};
  const data = (result as { data?: Record<string, unknown> } | undefined)?.data;
  if (data && typeof data === 'object') {
    const b64 = (data as Record<string, unknown>)['contentBase64'];
    if (typeof b64 === 'string') out.imageBase64 = b64;
    const fmt = (data as Record<string, unknown>)['format'];
    if (typeof fmt === 'string') out.format = fmt;
  }
  return out;
}

/** Otto packages RELAY-level failures (e.g. acl_missing_node_grant from a paired-
 *  but-ungranted node) as a NON-isError MCP result whose envelope messageType is
 *  "error" — so a thrown exception is NOT the only failure signal. Detect an
 *  in-band error envelope so we never report ok:true for a failed op. */
function envelopeError(result: unknown): string | undefined {
  const r = result as { response?: unknown; error?: unknown } | undefined;
  const env = (r?.response ?? r) as
    | { messageType?: unknown; payload?: unknown; code?: unknown; message?: unknown; ok?: unknown }
    | undefined;
  if (env && typeof env === 'object') {
    // (a) wrapped envelope: { response: { messageType:"error", payload:{code,message} } }
    if (env.messageType === 'error') {
      const p = (env.payload ?? {}) as { code?: unknown; message?: unknown; error?: unknown };
      const code = typeof p.code === 'string' ? p.code : 'error';
      const msg = typeof p.message === 'string' ? p.message : typeof p.error === 'string' ? p.error : '';
      return msg ? `${code}: ${msg}` : code;
    }
    // (b) flat command error: { code, message, ok!==true } (e.g. missing_tab_session)
    if (typeof env.code === 'string' && typeof env.message === 'string' && env.ok !== true) {
      return `${env.code}: ${env.message}`;
    }
  }
  if (r && typeof r === 'object' && typeof r.error === 'string') return r.error;
  return undefined;
}

function makeHandler(cfg: Config): (req: OttoRequest) => Promise<OttoResponse> {
  return async (req: OttoRequest): Promise<OttoResponse> => {
    switch (req.op) {
      case 'status':
        return handleStatus(cfg);
      case 'extract':
        return handleExtract(cfg, req);
      case 'screenshot':
        return handleScreenshot(cfg, req);
      default:
        return { op: 'error', ok: false, error: `unknown op: ${String((req as { op?: unknown }).op)}` };
    }
  };
}

async function handleStatus(cfg: Config): Promise<OttoResponse> {
  // 1. Relay reachability — zero-auth, zero-dependency (no browser node needed).
  const relay = await probeRelay(cfg.relayHttpUrl);

  // 2. Connected browser nodes — proves the controller/MCP path works end-to-end.
  let browserNodes: string[] = [];
  let mcpOk = false;
  let mcpError: string | undefined;
  try {
    const client = await getOttoMcpClient();
    const statusResult = (await client.callTool('otto_status', { nodes: true })) as {
      nodes?: unknown;
    };
    mcpOk = true;
    if (Array.isArray(statusResult?.nodes)) {
      browserNodes = statusResult.nodes.filter((n): n is string => typeof n === 'string');
    }
  } catch (err) {
    mcpError = (err as Error).message;
  }

  const browserConnected = browserNodes.length > 0;
  const resp: OttoResponse = {
    op: 'status',
    ok: relay.reachable,
    relay_url: cfg.relayHttpUrl,
    relay_reachable: relay.reachable,
    ...(relay.httpStatus !== undefined ? { relay_http_status: relay.httpStatus } : {}),
    controller_mcp_ok: mcpOk,
    ...(mcpError !== undefined ? { controller_mcp_error: mcpError } : {}),
    browser_nodes: browserNodes,
    browser_connected: browserConnected,
    note: browserConnected
      ? 'relay reachable; browser node(s) paired — extract/screenshot available'
      : 'relay reachable; NO browser node paired — extract/screenshot will error until the operator loads the otto extension in Chrome and pairs it',
  };
  log('info', 'status', { reachable: relay.reachable, mcpOk, browserConnected, nodes: browserNodes.length });
  return resp;
}

async function handleExtract(cfg: Config, req: OttoRequest): Promise<OttoResponse> {
  if (!req.url && !('tabSession' in req)) {
    return { op: 'extract', ok: false, error: 'extract: url is required' };
  }
  let client: OttoMcpClient;
  try {
    client = await getOttoMcpClient();
  } catch (err) {
    return { op: 'extract', ok: false, error: `otto mcp unavailable: ${(err as Error).message}` };
  }
  const args: Record<string, unknown> = {
    ...(req.url ? { url: req.url } : {}),
    format: req.format ?? 'markdown',
    ...(req.nodeId ? { nodeId: req.nodeId } : {}),
    ...(req.selector ? { selector: req.selector } : {}),
    ...(req.maxChars ? { maxChars: req.maxChars } : {}),
    timeout: req.timeoutMs ?? cfg.defaultTimeoutMs,
  };
  try {
    const result = await client.callTool('otto_extract_content', args);
    // Honest success signal: a relay error envelope (e.g. acl_missing_node_grant)
    // is NOT a thrown error, so check for it, and require real content.
    const inBand = envelopeError(result);
    if (inBand) {
      return { op: 'extract', ok: false, url: req.url, error: inBand, result };
    }
    const surfaced = surfaceExtract(result);
    const ok = surfaced.content !== undefined;
    return {
      op: 'extract',
      ok,
      url: req.url,
      format: args['format'] as string,
      ...(surfaced.content !== undefined ? { content: surfaced.content } : {}),
      ...(surfaced.title !== undefined ? { title: surfaced.title } : {}),
      ...(ok ? {} : { error: 'extract: no content returned (no browser node paired, or the page yielded no extractable content)' }),
      result,
    };
  } catch (err) {
    // otto's own error (e.g. no browser paired) — pass through honestly.
    return { op: 'extract', ok: false, error: (err as Error).message };
  }
}

async function handleScreenshot(cfg: Config, req: OttoRequest): Promise<OttoResponse> {
  if (!req.url) {
    return { op: 'screenshot', ok: false, error: 'screenshot: url is required' };
  }
  let client: OttoMcpClient;
  try {
    client = await getOttoMcpClient();
  } catch (err) {
    return { op: 'screenshot', ok: false, error: `otto mcp unavailable: ${(err as Error).message}` };
  }
  // Use the primitive.page.screenshot action (which navigates the URL itself),
  // NOT the otto_screenshot MCP tool — the latter routes through command.run
  // 'screenshot' which requires a pre-opened tabSession (missing_tab_session).
  // This mirrors otto's own CLI screenshot command (cite: cli/index.ts:2593).
  const args: Record<string, unknown> = {
    action: 'primitive.page.screenshot',
    payload: JSON.stringify({
      url: req.url,
      mode: 'viewport',
      format: req.format ?? 'png',
      quality: 80,
      maxBytes: 1_500_000,
    }),
    ...(req.nodeId ? { nodeId: req.nodeId } : {}),
    timeout: req.timeoutMs ?? cfg.defaultTimeoutMs,
  };
  try {
    const result = await client.callTool('otto_cmd', args);
    const inBand = envelopeError(result);
    if (inBand) {
      return { op: 'screenshot', ok: false, url: req.url, error: inBand, result };
    }
    const surfaced = surfaceScreenshot(result);
    const ok = surfaced.imageBase64 !== undefined;
    return {
      op: 'screenshot',
      ok,
      url: req.url,
      ...(surfaced.imageBase64 !== undefined ? { image_base64: surfaced.imageBase64 } : {}),
      ...(surfaced.format !== undefined ? { format: surfaced.format } : {}),
      ...(ok ? {} : { error: 'screenshot: no image returned (no browser node paired?)' }),
      result,
    };
  } catch (err) {
    return { op: 'screenshot', ok: false, error: (err as Error).message };
  }
}

/** Main lifecycle. Returns once the server is up; stays alive via the worker. */
export async function run(argv: string[]): Promise<void> {
  const flags = parseFlags(argv);
  const cfg = loadConfig();
  log('info', 'starting otto app', {
    addr: flags.addr,
    socket: flags.socket,
    daemonSocket: cfg.daemonSocketPath,
    relayHttpUrl: cfg.relayHttpUrl,
  });

  // Readiness socket FIRST so the supervisor sees us promptly. (We do NOT block
  // readiness on the otto mcp child — it connects lazily on the first capability
  // call, so the node is ready even before a browser is paired.)
  const appSock = await serveAppSocket(flags.socket);

  const handler = makeHandler(cfg);
  const server = await startCapabilityServer({
    daemonSocketPath: cfg.daemonSocketPath,
    port: CAPABILITY_PORT,
    onRequest: handler,
  });

  log('info', 'otto app ready', { port: CAPABILITY_PORT });

  const shutdown = (sig: string) => {
    log('info', 'shutting down', { signal: sig });
    server.close();
    appSock.close();
    void getOttoMcpClient().then((c) => c.close()).catch(() => undefined);
    process.exit(0);
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  // `db`/`manifest`/`capState` are accepted (supervisor contract) but unused by a
  // free, stateless node. Reference them so strict TS noUnusedLocals stays happy
  // if it is ever enabled, and keep the install-dir resolvable for diagnostics.
  void path.dirname(flags.socket);
}
