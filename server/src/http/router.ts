import type { IncomingMessage, ServerResponse } from 'node:http';
import { gunzipSync } from 'node:zlib';

/**
 * A small router over `node:http`, using the platform's own `URLPattern` for
 * path matching. Node 24 ships it, so there is no hand-written path parser
 * here and `/api/activities/:id` means what it says.
 */

export type Reply = {
  status: number;
  body?: unknown;
  headers?: Record<string, string>;
  /** Sent as-is when present, for GPX and other non-JSON answers. */
  text?: string;
};

export type Ctx = {
  method: string;
  url: URL;
  params: Record<string, string>;
  headers: NodeJS.Dict<string | string[]>;
  /** Client address, for rate limiting. */
  ip: string;
  /** Decoded, size-limited request body. Throws HttpError on a bad body. */
  body: () => Promise<unknown>;
};

export type Handler = (ctx: Ctx) => Promise<Reply> | Reply;

export type Route = {
  method: string;
  path: string;
  handler: Handler;
  /** Routes are protected unless they say otherwise. */
  public?: boolean;
};

export class HttpError extends Error {
  readonly status: number;
  readonly problems: string[];

  constructor(status: number, message: string, problems: string[] = []) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.problems = problems;
  }
}

/** 10 MB compressed. A two-hour run is about 100 KB, so this is generous. */
export const MAX_BODY_BYTES = 10 * 1024 * 1024;

type Compiled = Route & { pattern: URLPattern };

export function compile(routes: readonly Route[]): Compiled[] {
  return routes.map((route) => ({
    ...route,
    pattern: new URLPattern({ pathname: route.path }),
  }));
}

export type Middleware = (ctx: Ctx, route: Compiled) => Promise<void> | void;

export function createHandler(
  routes: readonly Route[],
  middleware: readonly Middleware[] = [],
): (req: IncomingMessage, res: ServerResponse) => Promise<void> {
  const compiled = compile(routes);

  return async (req, res) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
    const method = (req.method ?? 'GET').toUpperCase();

    const match = compiled.find(
      (route) =>
        route.method === method && route.pattern.test({ pathname: url.pathname }),
    );

    if (match === undefined) {
      // Distinguish an unknown path from a path that exists under another verb,
      // which is the difference between a typo and a client bug.
      const pathExists = compiled.some((route) =>
        route.pattern.test({ pathname: url.pathname }),
      );
      send(
        res,
        pathExists
          ? { status: 405, body: { error: 'method not allowed' } }
          : { status: 404, body: { error: 'not found' } },
      );
      return;
    }

    const groups = match.pattern.exec({ pathname: url.pathname })?.pathname.groups ?? {};
    const params: Record<string, string> = {};
    for (const [key, value] of Object.entries(groups)) {
      if (value !== undefined) params[key] = value;
    }

    const ctx: Ctx = {
      method,
      url,
      params,
      headers: req.headers,
      ip: clientIp(req),
      body: () => readJsonBody(req),
    };

    try {
      for (const step of middleware) {
        await step(ctx, match);
      }
      send(res, await match.handler(ctx));
    } catch (error) {
      if (error instanceof HttpError) {
        send(res, {
          status: error.status,
          body: {
            error: error.message,
            ...(error.problems.length > 0 ? { problems: error.problems } : {}),
          },
        });
        return;
      }
      // Nothing internal reaches the client. One user, but the habit matters.
      console.error('unhandled error', error);
      send(res, { status: 500, body: { error: 'internal error' } });
    }
  };
}

function send(res: ServerResponse, reply: Reply): void {
  const headers: Record<string, string> = {
    // Sent even without TLS in front, so a misconfigured proxy does not
    // silently drop it.
    'strict-transport-security': 'max-age=31536000; includeSubDomains',
    'x-content-type-options': 'nosniff',
    ...reply.headers,
  };

  if (reply.text !== undefined) {
    headers['content-type'] ??= 'text/plain; charset=utf-8';
    res.writeHead(reply.status, headers);
    res.end(reply.text);
    return;
  }

  const payload = reply.body === undefined ? '' : JSON.stringify(reply.body);
  if (payload !== '') headers['content-type'] = 'application/json; charset=utf-8';
  res.writeHead(reply.status, headers);
  res.end(payload);
}

function clientIp(req: IncomingMessage): string {
  // Caddy sits in front, so the socket address is always the proxy. Only the
  // last hop is trusted; anything further left in the header is client-supplied
  // and can say whatever it likes.
  const forwarded = req.headers['x-forwarded-for'];
  const raw = Array.isArray(forwarded) ? forwarded[0] : forwarded;
  const last = raw?.split(',').pop()?.trim();
  return last !== undefined && last !== ''
    ? last
    : (req.socket.remoteAddress ?? 'unknown');
}

async function readJsonBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let total = 0;

  for await (const chunk of req) {
    const buffer = chunk as Buffer;
    total += buffer.byteLength;
    if (total > MAX_BODY_BYTES) {
      throw new HttpError(413, 'body too large');
    }
    chunks.push(buffer);
  }

  let raw = Buffer.concat(chunks);
  if (raw.byteLength === 0) throw new HttpError(400, 'body is empty');

  const encoding = req.headers['content-encoding'];
  if (typeof encoding === 'string' && encoding.toLowerCase().includes('gzip')) {
    try {
      raw = gunzipSync(raw);
    } catch {
      throw new HttpError(400, 'body is not valid gzip');
    }
  }

  try {
    return JSON.parse(raw.toString('utf8')) as unknown;
  } catch {
    throw new HttpError(400, 'body is not valid JSON');
  }
}
