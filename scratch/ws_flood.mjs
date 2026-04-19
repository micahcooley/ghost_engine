import net from "node:net";
import crypto from "node:crypto";

const host = process.env.GHOST_HOST ?? "127.0.0.1";
const port = Number.parseInt(process.env.GHOST_PORT ?? "8080", 10);
const path = process.env.GHOST_WS_PATH ?? "/?channel=chat";
const statsUrl = process.env.GHOST_STATS_URL ?? `http://${host}:${port}/api/stats`;
const clients = Number.parseInt(process.env.GHOST_CLIENTS ?? "64", 10);
const durationMs = Number.parseInt(process.env.GHOST_DURATION_MS ?? "20000", 10);
const connectTimeoutMs = Number.parseInt(process.env.GHOST_CONNECT_TIMEOUT_MS ?? "10000", 10);
const maxRequestsPerClient = Number.parseInt(process.env.GHOST_MAX_REQUESTS_PER_CLIENT ?? "0", 10);

const prompts = [
  "The Ghost Engine is",
  "Bitwise resonance means",
  "Summarize the lattice",
  "What is sovereign compute",
  "Describe the semantic monolith",
  "Explain the hamming drift",
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const metrics = {
  connected: 0,
  connect_failed: 0,
  requests_started: 0,
  requests_done: 0,
  requests_failed: 0,
  forced_shutdowns: 0,
  socket_errors: 0,
  socket_closed_early: 0,
  done_without_output: 0,
  stats_ok: 0,
  stats_failed: 0,
  bytes_received: 0,
  latencies_ms: [],
};

let stopRequested = false;
const deadline = Date.now() + durationMs;

function promptFor(id, seq) {
  const base = prompts[(id + seq) % prompts.length];
  return `${base} [client=${id} seq=${seq}]`;
}

function encodeFrame(text) {
  const payload = Buffer.from(text, "utf8");
  const mask = crypto.randomBytes(4);
  let header;

  if (payload.length < 126) {
    header = Buffer.alloc(2);
    header[1] = 0x80 | payload.length;
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    throw new Error("payload too large for test harness");
  }

  header[0] = 0x81;
  const masked = Buffer.alloc(payload.length);
  for (let i = 0; i < payload.length; i += 1) {
    masked[i] = payload[i] ^ mask[i % 4];
  }
  return Buffer.concat([header, mask, masked]);
}

class RawWsClient {
  constructor(id) {
    this.id = id;
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.handshaken = false;
    this.opened = false;
    this.closed = false;
    this.active = null;
    this.requestSeq = 0;
    this.connectTimer = null;
    this.handshakeResolve = null;
    this.handshakeReject = null;
    this.closeResolve = null;
    this.expectedClose = false;
  }

  async run() {
    const closePromise = new Promise((resolve) => {
      this.closeResolve = resolve;
    });

    await new Promise((resolve, reject) => {
      this.handshakeResolve = resolve;
      this.handshakeReject = reject;
      this.socket = net.createConnection({ host, port });
      this.connectTimer = setTimeout(() => reject(new Error("connect timeout")), connectTimeoutMs);

      this.socket.on("connect", () => {
        const key = crypto.randomBytes(16).toString("base64");
        const req =
          `GET ${path} HTTP/1.1\r\n` +
          `Host: ${host}:${port}\r\n` +
          `Upgrade: websocket\r\n` +
          `Connection: Upgrade\r\n` +
          `Sec-WebSocket-Key: ${key}\r\n` +
          `Sec-WebSocket-Version: 13\r\n\r\n`;
        this.socket.write(req);
      });

      this.socket.on("data", (chunk) => this.onData(chunk));
      this.socket.on("error", (error) => {
        metrics.socket_errors += 1;
        if (!this.handshaken) {
          reject(error);
        }
      });
      this.socket.on("close", () => {
        this.closed = true;
        if (!this.opened) {
          metrics.connect_failed += 1;
          reject(new Error("socket closed before handshake"));
          this.closeResolve?.();
          return;
        }
        if (!stopRequested && Date.now() < deadline) {
          if (!this.expectedClose) metrics.socket_closed_early += 1;
        }
        this.closeResolve?.();
      });
    });

    await closePromise;
  }

  closeNow() {
    if (this.closed) return;
    this.socket?.destroy();
  }

  onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);

    if (!this.handshaken) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) return;
      const header = this.buffer.subarray(0, headerEnd + 4).toString("utf8");
      this.buffer = this.buffer.subarray(headerEnd + 4);

      if (!header.startsWith("HTTP/1.1 101")) {
        this.handshakeReject?.(new Error(`unexpected handshake response: ${header.split("\r\n")[0]}`));
        this.socket.destroy();
        return;
      }

      clearTimeout(this.connectTimer);
      this.handshaken = true;
      this.opened = true;
      metrics.connected += 1;
      this.handshakeResolve?.();
      this.handshakeResolve = null;
      this.handshakeReject = null;
    }

    while (this.handshaken) {
      if (this.buffer.length < 2) return;
      const b0 = this.buffer[0];
      const b1 = this.buffer[1];
      const opcode = b0 & 0x0f;
      let offset = 2;
      let len = b1 & 0x7f;

      if (len === 126) {
        if (this.buffer.length < 4) return;
        len = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (len === 127) {
        throw new Error("server frame too large for test harness");
      }

      const masked = (b1 & 0x80) !== 0;
      const maskBytes = masked ? 4 : 0;
      if (this.buffer.length < offset + maskBytes + len) return;

      let payload = this.buffer.subarray(offset + maskBytes, offset + maskBytes + len);
      if (masked) {
        const mask = this.buffer.subarray(offset, offset + 4);
        const unmasked = Buffer.alloc(len);
        for (let i = 0; i < len; i += 1) unmasked[i] = payload[i] ^ mask[i % 4];
        payload = unmasked;
      }

      this.buffer = this.buffer.subarray(offset + maskBytes + len);

      if (opcode === 0x8) {
        this.socket.end();
        return;
      }

      if (opcode !== 0x1) continue;
      this.handleMessage(payload.toString("utf8"));
    }
  }

  handleMessage(text) {
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      metrics.requests_failed += 1;
      this.active = null;
      return;
    }

    if (message.type === "connected") {
      if (!this.active) this.sendNext();
      return;
    }

    if (!this.active) return;

    if (message.type === "output") {
      this.active.gotOutput = true;
      metrics.bytes_received += typeof message.text === "string" ? Buffer.byteLength(message.text) : 0;
      return;
    }

    if (message.type === "error") {
      this.active.gotError = true;
      return;
    }

    if (message.type === "done") {
      const latency = performance.now() - this.active.startedAt;
      metrics.latencies_ms.push(latency);
      if (this.active.gotError) {
        metrics.requests_failed += 1;
      } else {
        metrics.requests_done += 1;
        if (!this.active.gotOutput) metrics.done_without_output += 1;
      }
      this.active = null;
      this.sendNext();
    }
  }

  sendNext() {
    if (maxRequestsPerClient > 0 && this.requestSeq >= maxRequestsPerClient) {
      this.expectedClose = true;
      this.socket.end();
      return;
    }
    if (stopRequested || Date.now() >= deadline) {
      this.expectedClose = true;
      this.socket.end();
      return;
    }
    const text = promptFor(this.id, this.requestSeq);
    this.requestSeq += 1;
    this.active = {
      startedAt: performance.now(),
      gotOutput: false,
      gotError: false,
    };
    metrics.requests_started += 1;
    this.socket.write(encodeFrame(JSON.stringify({ type: "input", text })));
  }
}

async function pollStats() {
  while (!stopRequested) {
    try {
      const response = await fetch(statsUrl, { method: "GET" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      await response.arrayBuffer();
      metrics.stats_ok += 1;
    } catch {
      metrics.stats_failed += 1;
    }
    await sleep(500);
  }
}

function percentile(values, p) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

async function main() {
  const statsTask = pollStats();
  const clientTasks = [];
  const liveClients = [];
  for (let i = 0; i < clients; i += 1) {
    const client = new RawWsClient(i);
    liveClients.push(client);
    clientTasks.push(client.run());
  }

  const watchdog = setTimeout(() => {
    stopRequested = true;
    let forced = 0;
    for (const client of liveClients) {
      if (!client.closed) {
        forced += 1;
        client.closeNow();
      }
    }
    metrics.forced_shutdowns += forced;
  }, durationMs + 10000);

  await Promise.allSettled(clientTasks);
  clearTimeout(watchdog);
  stopRequested = true;
  await statsTask;

  const requests_unfinished = metrics.requests_started - (metrics.requests_done + metrics.requests_failed);

  const summary = {
    clients,
    durationMs,
    maxRequestsPerClient,
    ...metrics,
    requests_unfinished,
    p50_ms: Number(percentile(metrics.latencies_ms, 50).toFixed(2)),
    p95_ms: Number(percentile(metrics.latencies_ms, 95).toFixed(2)),
    p99_ms: Number(percentile(metrics.latencies_ms, 99).toFixed(2)),
  };

  console.log(JSON.stringify(summary, null, 2));

  const totalFinished = metrics.requests_done + metrics.requests_failed;
  if (
    metrics.connect_failed !== 0 ||
    metrics.socket_errors !== 0 ||
    metrics.socket_closed_early !== 0 ||
    metrics.stats_failed !== 0 ||
    requests_unfinished !== 0 ||
    metrics.requests_failed !== 0
  ) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
