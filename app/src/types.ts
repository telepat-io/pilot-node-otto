/**
 * Shared type contract for the io.telepat.otto Pilot app-store app.
 *
 * This is a FREE node (no payment): there is no wallet IPC, no quote/deliver,
 * no dedupe. The app exposes ONE dataexchange capability — a thin, honest bridge
 * to the telepat.io "otto" browser-automation agent over its stdio MCP.
 *
 * Two distinct wire formats are in play and MUST NOT be conflated:
 *
 *   1. dataexchange frame  — peer<->peer over the Pilot overlay, port 1001.
 *      [4B type BE][4B len BE][payload]. See DxFrame / DxType below.
 *      Upstream: org/dataexchange/dataexchange.go:64-93.
 *
 *   2. app-store IPC envelope — app<->daemon/app over a unix socket.
 *      [4B len BE][JSON Envelope]. See IpcEnvelope below.
 *      Upstream: org/app-store/pkg/ipc/frame.go:15-69, envelope.go:33-41.
 */

// ───────────────────────────────────────────────────────────────────────────
// dataexchange wire (peer <-> peer, port 1001)
// ───────────────────────────────────────────────────────────────────────────

/** dataexchange frame type discriminator.
 *  Upstream: org/dataexchange/dataexchange.go:15-23 (TypeTrace=5 unused by us). */
export enum DxType {
  TEXT = 1,
  BINARY = 2,
  JSON = 3,
  FILE = 4,
}

/** A decoded dataexchange frame. For FILE frames, `filename` is set and
 *  `payload` is the raw file bytes; for TEXT/JSON/BINARY `filename` is undefined. */
export interface DxFrame {
  type: DxType;
  payload: Buffer;
  filename?: string;
}

// ───────────────────────────────────────────────────────────────────────────
// app-store IPC envelope (app <-> daemon)
// ───────────────────────────────────────────────────────────────────────────

export type IpcEnvelopeType = 'req' | 'reply' | 'err';

/** The single message shape on the app-store IPC wire.
 *  Upstream: org/app-store/pkg/ipc/envelope.go:33-41. */
export interface IpcEnvelope {
  type: IpcEnvelopeType;
  req_id: string;
  method?: string;
  app_id?: string;
  manifest_version?: number;
  payload?: unknown;
  error?: string;
}

// ───────────────────────────────────────────────────────────────────────────
// our app's peer-facing protocol (carried inside a dataexchange JSON frame)
// ───────────────────────────────────────────────────────────────────────────

/** The capability ops this node accepts. */
export type OttoOp = 'status' | 'extract' | 'screenshot';

/** Request frame our capability server accepts (decoded from a DxType.JSON
 *  frame on port 1001).
 *
 *  - {op:"status"}                      -> relay health + connected browser nodes
 *  - {op:"extract", url, format?}       -> otto_extract_content (markdown by default)
 *  - {op:"screenshot", url, format?}    -> otto_screenshot
 *
 *  `nodeId` may pin a specific paired browser node; otherwise otto auto-resolves
 *  the single connected node (errors honestly if none/ambiguous). */
export interface OttoRequest {
  op: OttoOp;
  /** Required for extract (unless tabSession) and screenshot. */
  url?: string;
  /** extract: markdown|distilled_html|clean_html|raw_html|text (default markdown).
   *  screenshot: png|jpeg (otto default). */
  format?: string;
  /** Pin a specific paired browser node id. */
  nodeId?: string;
  /** Per-call timeout (ms) forwarded to the otto tool. */
  timeoutMs?: number;
  /** extract only: CSS selector for raw_html/clean_html/text. */
  selector?: string;
  /** extract only: cap extracted characters. */
  maxChars?: number;
}

/** Reply frame. `op` echoes the request; `ok` is the honest success signal.
 *  Op-specific fields ride alongside (index signature keeps the transport
 *  layer in pilotServer.ts agnostic to the payload shape). */
export interface OttoResponse {
  op: string;
  ok: boolean;
  error?: string;
  [k: string]: unknown;
}

// ───────────────────────────────────────────────────────────────────────────
// lifecycle flags (supervisor -> our binary)
// ───────────────────────────────────────────────────────────────────────────

/** Flags the app-store supervisor passes to a spawned app.
 *  Upstream: org/app-store/plugin/appstore/supervisor.go:752-759. */
export interface LifecycleFlags {
  addr: string;
  db: string;
  socket: string;
  identity: string;
  manifest: string;
  capState: string;
}

// ───────────────────────────────────────────────────────────────────────────
// module stub SIGNATURES — implementations live in the named files
// ───────────────────────────────────────────────────────────────────────────

/** dxframe.ts — encode/decode dataexchange frames. */
export interface DxFrameModule {
  encodeFrame(type: DxType, payload: Buffer): Buffer;
  decodeFrame(buf: Buffer): { frame: DxFrame; bytesRead: number };
  encodeFilePayload(filename: string, data: Buffer): Buffer;
}
export declare const encodeFrame: DxFrameModule['encodeFrame'];
export declare const decodeFrame: DxFrameModule['decodeFrame'];
export declare const encodeFilePayload: DxFrameModule['encodeFilePayload'];

/** A connection-like handle exposing the subset of sdk-node Conn we use. */
export interface ConnLike {
  read(size?: number): Buffer;
  write(data: Buffer | Uint8Array | string): number;
  close(): void;
}

/** appSock.ts — create the --socket unix listener the supervisor polls for
 *  readiness. We expose no callable methods in v1; the socket is the readiness
 *  signal. Upstream readiness poll: supervisor.go:795-808. */
export interface AppSockModule {
  serveAppSocket(socketPath: string): Promise<AppSockHandle>;
}
export interface AppSockHandle {
  close(): void;
}
export declare const serveAppSocket: AppSockModule['serveAppSocket'];

/** pilotServer.ts — bind the daemon data plane on the capability port and serve
 *  our capability to peers. Uses sdk-node Driver.listen(1001). */
export interface PilotServerModule {
  startCapabilityServer(opts: CapabilityServerOpts): Promise<CapabilityServerHandle>;
}
export interface CapabilityServerOpts {
  daemonSocketPath: string;
  port: number;
  onRequest(req: OttoRequest): Promise<OttoResponse>;
}
export interface CapabilityServerHandle {
  close(): void;
}
export declare const startCapabilityServer: PilotServerModule['startCapabilityServer'];

/** mcpStdioClient.ts — drive the otto stdio MCP (`otto mcp`) as a child. */
export interface OttoMcpClientModule {
  getOttoMcpClient(opts?: OttoMcpClientOpts): Promise<OttoMcpClient>;
}
export interface OttoMcpClientOpts {
  /** Override the otto binary (default "otto"). */
  command?: string;
  /** Extra env merged over process.env for the otto mcp child. */
  env?: Record<string, string>;
}
export interface OttoMcpClient {
  /** Call an otto MCP tool; returns the parsed structured result.
   *  Throws on isError (the otto tool's own error text). */
  callTool(name: string, args?: Record<string, unknown>): Promise<unknown>;
  close(): Promise<void>;
}
