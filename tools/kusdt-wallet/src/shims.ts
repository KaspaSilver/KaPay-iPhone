// Runs before any of Trestly's modules (entry.ts imports it first). KaPay's hidden page has no
// network of its own for HTTP and no chrome.storage:
// - fetch goes through KaPay (`kusdtNet`), which answers only https requests to the Kaspa resolvers
//   (*.kaspa.stream, .red, .green, .blue) and to the Trestly API set in KaPay's Settings.
// - chrome.storage.local is kept by KaPay (`kusdtStore`, on the phone); session stays in memory.
// The node connection itself is the WebSocket their node client opens to the node a resolver names
// (their code accepts only wss://<name>.kaspa.(stream|red|green|blue)).

type Reply = { error?: string; status?: number; headers?: Record<string, string>; body?: string | null; value?: unknown };
const handlers = (globalThis as any).webkit?.messageHandlers ?? {};
const post = (name: string, message: unknown): Promise<Reply> => {
  const h = handlers[name];
  if (!h) return Promise.reject(new Error(`KaPay bridge ${name} is missing`));
  return h.postMessage(message) as Promise<Reply>;
};

(globalThis as any).fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  const method = (init?.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase();
  const headers: Record<string, string> = {};
  new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined)).forEach((v, k) => { headers[k] = v; });
  const body = typeof init?.body === 'string' ? init.body : null;
  if (init?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
  const answer = await post('kusdtNet', { url, method, headers, body });
  if (init?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
  if (answer.error) throw new TypeError(answer.error);
  const status = answer.status ?? 0;
  const noBody = status === 204 || status === 304 || method === 'HEAD';
  return new Response(noBody ? null : (answer.body ?? ''), { status, headers: answer.headers ?? {} });
};

const area = {
  get(keys: string | string[], callback: (items: Record<string, unknown>) => void) {
    const list = Array.isArray(keys) ? keys : [keys];
    post('kusdtStore', { op: 'get', keys: list })
      .then((a) => callback((a.value as Record<string, unknown>) ?? {}), () => callback({}));
  },
  set(values: Record<string, unknown>, callback?: () => void) {
    post('kusdtStore', { op: 'set', values: JSON.parse(JSON.stringify(values)) })
      .then(() => callback?.(), () => callback?.());
  },
  remove(keys: string | string[], callback?: () => void) {
    post('kusdtStore', { op: 'remove', keys: Array.isArray(keys) ? keys : [keys] })
      .then(() => callback?.(), () => callback?.());
  },
};
(globalThis as any).chrome = { storage: { local: area }, runtime: {} };

export {};
