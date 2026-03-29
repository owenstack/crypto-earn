import { test, expect, describe, beforeAll, afterAll } from "bun:test";
import { IPCClient } from "../src/ipc/client.ts";
import type { Envelope } from "../src/ipc/types.ts";
import { unlinkSync } from "node:fs";

const SOCK_PATH = `/tmp/cex-test-${Date.now()}-${Math.random().toString(36).slice(2)}.sock`;

let server: ReturnType<typeof Bun.listen> | null = null;

function startEchoServer() {
  return Bun.listen({
    unix: SOCK_PATH,
    socket: {
      data(socket, raw: Buffer) {
        const text = raw.toString("utf8");
        const lines = text.split("\n").filter(Boolean);
        for (const line of lines) {
          try {
            const req = JSON.parse(line) as Envelope;
            const response: Envelope = {
              v: 1,
              id: req.id,
              ts: Date.now(),
              type: `${req.type}.response` as Envelope["type"],
              payload: { echo: true },
            };
            socket.write(JSON.stringify(response) + "\n");
          } catch {
            // ignore malformed
          }
        }
      },
      open() {},
      close() {},
      error() {},
    },
  });
}

beforeAll(() => {
  server = startEchoServer();
});

afterAll(() => {
  server?.stop(true);
  try {
    unlinkSync(SOCK_PATH);
  } catch {}
});

describe("IPCClient", () => {
  test("constructor defaults are sensible", () => {
    const client = new IPCClient();
    expect(client.connected).toBe(false);
  });

  test("connects to the socket", async () => {
    const client = new IPCClient({
      socketPath: SOCK_PATH,
      connectTimeoutMs: 3000,
      maxInitialAttempts: 3,
    });
    await client.connect();
    expect(client.connected).toBe(true);
    client.disconnect();
  });

  test("request sends JSON line and receives correlated response", async () => {
    const client = new IPCClient({
      socketPath: SOCK_PATH,
      requestTimeoutMs: 3000,
    });
    await client.connect();

    const res = await client.request("status");
    expect(res.v).toBe(1);
    expect(res.type).toBe("status.response");
    expect(res.payload).toEqual({ echo: true });

    client.disconnect();
  });

  test("connected property reflects actual state", async () => {
    const client = new IPCClient({ socketPath: SOCK_PATH });
    expect(client.connected).toBe(false);

    await client.connect();
    expect(client.connected).toBe(true);

    client.disconnect();
    expect(client.connected).toBe(false);
  });

  test("disconnection rejects pending requests", async () => {
    // Start a server that doesn't respond, so the request stays pending
    const silentSock = `/tmp/cex-test-silent-${Date.now()}.sock`;
    const silentServer = Bun.listen({
      unix: silentSock,
      socket: {
        data() {},
        open() {},
        close() {},
        error() {},
      },
    });

    try {
      const silentClient = new IPCClient({
        socketPath: silentSock,
        requestTimeoutMs: 10_000,
      });
      await silentClient.connect();

      // Start the request and immediately capture the rejection
      const promise = silentClient.request("status").then(
        () => { throw new Error("should not resolve"); },
        (err) => err,
      );

      // Disconnect while request is pending
      silentClient.disconnect();

      // Wait for the promise to reject (with timeout fallback)
      const err = await Promise.race([
        promise,
        new Promise<Error>(resolve => setTimeout(() => resolve(new Error("timeout")), 1000)),
      ]);

      expect(err).toBeInstanceOf(Error);
      expect((err as Error).message).not.toBe("timeout");
    } finally {
      silentServer.stop(true);
      try { unlinkSync(silentSock); } catch {}
    }
  });

  test("request timeout triggers rejection", async () => {
    // Server that never responds
    const timeoutSock = `/tmp/cex-test-timeout-${Date.now()}.sock`;
    const timeoutServer = Bun.listen({
      unix: timeoutSock,
      socket: {
        data() {},
        open() {},
        close() {},
        error() {},
      },
    });

    const client = new IPCClient({
      socketPath: timeoutSock,
      requestTimeoutMs: 100,
    });
    await client.connect();

    try {
      try {
        await client.request("heartbeat");
        throw new Error("Expected request to fail");
      } catch (err) {
        expect(err).toBeInstanceOf(Error);
        expect((err as Error).message).toContain("IPC timeout");
      }
    } finally {
      client.disconnect();
      timeoutServer.stop(true);
      try { unlinkSync(timeoutSock); } catch {}
    }
  });

  test("connect fails when no server is listening", async () => {
    const client = new IPCClient({
      socketPath: `/tmp/cex-test-nonexistent-${Date.now()}.sock`,
      connectTimeoutMs: 500,
      maxInitialAttempts: 2,
    });

    try {
      await client.connect();
      expect(true).toBe(false);
    } catch (err) {
      expect(err).toBeInstanceOf(Error);
    }
  });

  describe("Phase 3 strategy message types", () => {
    test("strategy.list request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("strategy.list");
      expect(res.v).toBe(1);
      expect(res.type).toBe("strategy.list.response");

      client.disconnect();
    });

    test("strategy.enable request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("strategy.enable", { name: "news_repricing" });
      expect(res.v).toBe(1);
      expect(res.type).toBe("strategy.enable.response");

      client.disconnect();
    });

    test("strategy.disable request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("strategy.disable", { name: "liquidity_provision" });
      expect(res.v).toBe(1);
      expect(res.type).toBe("strategy.disable.response");

      client.disconnect();
    });

    test("strategyList helper works", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.strategyList();
      expect(res.v).toBe(1);
      expect(res.type).toBe("strategy.list.response");

      client.disconnect();
    });

    test("strategyEnable helper works", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.strategyEnable("news_repricing");
      expect(res.v).toBe(1);
      expect(res.type).toBe("strategy.enable.response");

      client.disconnect();
    });

    test("strategyDisable helper works", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.strategyDisable("liquidity_provision");
      expect(res.v).toBe(1);
      expect(res.type).toBe("strategy.disable.response");

      client.disconnect();
    });
  });

  describe("Phase 2 message types", () => {
    test("order.place request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("order.place", {
        market_id: "test-market",
        side: "buy",
        size: "10",
        price: "0.50",
        order_type: "limit",
      });
      expect(res.v).toBe(1);
      expect(res.type).toBe("order.place.response");

      client.disconnect();
    });

    test("halt request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("halt");
      expect(res.v).toBe(1);
      expect(res.type).toBe("halt.response");

      client.disconnect();
    });

    test("resume request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("resume");
      expect(res.v).toBe(1);
      expect(res.type).toBe("resume.response");

      client.disconnect();
    });
  });
});
