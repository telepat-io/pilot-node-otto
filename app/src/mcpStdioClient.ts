/**
 * mcpStdioClient.ts — drive the otto agent's stdio MCP server (`otto mcp`).
 *
 * otto's MCP transport is STDIO (packages/cli/src/mcp/server.ts: StdioServerTransport).
 * We spawn `otto mcp` as a CHILD of this app (same container) and speak MCP over
 * its stdin/stdout via @modelcontextprotocol/sdk's StdioClientTransport. One
 * persistent Client is reused across capability calls; it is connected lazily on
 * first use and re-spawned if the child dies.
 *
 * The otto MCP child reads its controller credentials + relay URL from
 * ~/.otto/config.json (config dir = $HOME/.otto) and the OTTO_CONTROLLER_CLIENT_SECRET
 * env var — both provisioned by scripts/provider-entrypoint.sh before the daemon
 * (and therefore this app, and therefore this child) starts. We forward the full
 * process env so HOME + OTTO_CONTROLLER_CLIENT_SECRET reach the child.
 *
 * Tool result shape (every otto tool, cite: mcp/server.ts):
 *   success -> { content: [{type:'text', text: JSON.stringify(result)}], structuredContent: result }
 *   failure -> { content: [{type:'text', text: <message>}], isError: true }
 * We return `structuredContent` when present, else parse content[0].text as JSON,
 * else return the raw text. On isError we THROW the otto error text verbatim so
 * the caller can surface an honest failure (e.g. "Missing targetNodeId ..." when
 * no browser node is paired).
 */

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import type { OttoMcpClient, OttoMcpClientOpts } from './types.js';
import { log } from './log.js';

interface CallToolResultLike {
  content?: Array<{ type: string; text?: string }>;
  structuredContent?: unknown;
  isError?: boolean;
}

class StdioOttoClient implements OttoMcpClient {
  private readonly command: string;
  private readonly env: Record<string, string>;
  private client: Client | undefined;
  private transport: StdioClientTransport | undefined;
  private connecting: Promise<Client> | undefined;

  constructor(opts: OttoMcpClientOpts) {
    this.command = opts.command ?? 'otto';
    // Forward the full environment (HOME, OTTO_CONTROLLER_CLIENT_SECRET, …) and
    // layer any explicit overrides on top. Drop undefined values for the typed
    // env record the transport expects.
    const base: Record<string, string> = {};
    for (const [k, v] of Object.entries(process.env)) {
      if (typeof v === 'string') base[k] = v;
    }
    this.env = { ...base, ...(opts.env ?? {}) };
  }

  private async connect(): Promise<Client> {
    if (this.client) return this.client;
    if (this.connecting) return this.connecting;

    this.connecting = (async () => {
      const transport = new StdioClientTransport({
        command: this.command,
        args: ['mcp'],
        env: this.env,
        // otto logs to stderr; surface it in our own stderr stream for debugging.
        stderr: 'inherit',
      });
      const client = new Client(
        { name: 'io.telepat.otto-wrapper', version: '0.1.0' },
        { capabilities: {} },
      );
      // If the child exits, drop the cached client so the next call re-spawns.
      transport.onclose = () => {
        log('warn', 'otto mcp transport closed; will re-spawn on next call', {});
        this.client = undefined;
        this.transport = undefined;
      };
      await client.connect(transport);
      this.client = client;
      this.transport = transport;
      log('info', 'connected to otto mcp child', { command: this.command });
      return client;
    })();

    try {
      return await this.connecting;
    } catch (err) {
      log('error', 'failed to connect to otto mcp child', { error: (err as Error).message });
      this.client = undefined;
      this.transport = undefined;
      throw err;
    } finally {
      this.connecting = undefined;
    }
  }

  async callTool(name: string, args: Record<string, unknown> = {}): Promise<unknown> {
    const client = await this.connect();
    const res = (await client.callTool({ name, arguments: args })) as CallToolResultLike;

    if (res.isError) {
      const text = res.content?.find((c) => c.type === 'text')?.text ?? `otto tool ${name} failed`;
      throw new Error(text);
    }
    if (res.structuredContent !== undefined && res.structuredContent !== null) {
      return res.structuredContent;
    }
    const text = res.content?.find((c) => c.type === 'text')?.text;
    if (text === undefined) return {};
    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  }

  async close(): Promise<void> {
    try {
      await this.transport?.close();
    } catch {
      /* ignore */
    }
    this.client = undefined;
    this.transport = undefined;
  }
}

let singleton: StdioOttoClient | undefined;

/** Return the process-wide otto MCP client (spawns `otto mcp` lazily). */
export async function getOttoMcpClient(opts: OttoMcpClientOpts = {}): Promise<OttoMcpClient> {
  if (!singleton) {
    singleton = new StdioOttoClient(opts);
  }
  return singleton;
}
