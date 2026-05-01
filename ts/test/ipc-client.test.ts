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
            // Zig contract: ipc_types.T.pnl_response = "pnl.response".
            const responseType = req.type === "pnl.query"
              ? "pnl.response"
              : `${req.type}.response`;
            const response: Envelope = {
              v: 1,
              id: req.id,
              ts: Date.now(),
              type: responseType as Envelope["type"],
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

  test("request-specific timeout overrides the default timeout", async () => {
    const slowSock = `/tmp/cex-test-slow-${Date.now()}.sock`;
    const slowServer = Bun.listen({
      unix: slowSock,
      socket: {
        data(socket, raw: Buffer) {
          const text = raw.toString("utf8");
          const lines = text.split("\n").filter(Boolean);
          for (const line of lines) {
            const req = JSON.parse(line) as Envelope;
            setTimeout(() => {
              const response: Envelope = {
                v: 1,
                id: req.id,
                ts: Date.now(),
                type: `${req.type}.response` as Envelope["type"],
                payload: { slow: true },
              };
              socket.write(JSON.stringify(response) + "\n");
            }, 150);
          }
        },
        open() {},
        close() {},
        error() {},
      },
    });

    try {
      const client = new IPCClient({
        socketPath: slowSock,
        requestTimeoutMs: 50,
      });
      await client.connect();

      const res = await client.request("status", { timeoutMs: 300 });
      expect(res.payload).toEqual({ slow: true });

      client.disconnect();
    } finally {
      slowServer.stop(true);
      try { unlinkSync(slowSock); } catch {}
    }
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

  describe("Phase 4 event subscription", () => {
    test("event.subscribe request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("event.subscribe");
      expect(res.v).toBe(1);
      expect(res.type).toBe("event.subscribe.response");

      client.disconnect();
    });

    test("event.unsubscribe request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("event.unsubscribe");
      expect(res.v).toBe(1);
      expect(res.type).toBe("event.unsubscribe.response");

      client.disconnect();
    });

    test("subscribe helper sets subscribed state", async () => {
      // We need a server that replies with {"status":"subscribed"} for event.subscribe
      const subSock = `/tmp/cex-test-sub-${Date.now()}.sock`;
      const subServer = Bun.listen({
        unix: subSock,
        socket: {
          data(socket, raw: Buffer) {
            const text = raw.toString("utf8");
            const lines = text.split("\n").filter(Boolean);
            for (const line of lines) {
              try {
                const req = JSON.parse(line);
                if (req.type === "event.subscribe") {
                  socket.write(JSON.stringify({
                    v: 1, id: req.id, ts: Date.now(),
                    type: "event.subscribe.response",
                    payload: { status: "subscribed" },
                  }) + "\n");
                } else if (req.type === "event.unsubscribe") {
                  socket.write(JSON.stringify({
                    v: 1, id: req.id, ts: Date.now(),
                    type: "event.unsubscribe.response",
                    payload: { status: "unsubscribed" },
                  }) + "\n");
                }
              } catch {}
            }
          },
          open() {},
          close() {},
          error() {},
        },
      });

      try {
        const client = new IPCClient({ socketPath: subSock, requestTimeoutMs: 3000 });
        await client.connect();
        await client.subscribe();
        expect(client.subscribed).toBe(true);
        await client.unsubscribe();
        expect(client.subscribed).toBe(false);
        client.disconnect();
      } finally {
        subServer.stop(true);
        try { unlinkSync(subSock); } catch {}
      }
    });

    test("onEvent receives pushed events", async () => {
      const pushSock = `/tmp/cex-test-push-${Date.now()}.sock`;
      let pushSocket: any = null;

      const pushServer = Bun.listen({
        unix: pushSock,
        socket: {
          data(socket, raw: Buffer) {
            const text = raw.toString("utf8");
            const lines = text.split("\n").filter(Boolean);
            for (const line of lines) {
              try {
                const req = JSON.parse(line);
                // Reply to subscribe
                if (req.type === "event.subscribe") {
                  socket.write(JSON.stringify({
                    v: 1, id: req.id, ts: Date.now(),
                    type: "event.subscribe.response",
                    payload: { status: "subscribed" },
                  }) + "\n");
                  pushSocket = socket;
                }
              } catch {}
            }
          },
          open() {},
          close() {},
          error() {},
        },
      });

      try {
        const client = new IPCClient({ socketPath: pushSock, requestTimeoutMs: 3000 });
        await client.connect();
        await client.subscribe();

        const received: any[] = [];
        client.onEvent("event.order.placed" as any, (env) => {
          received.push(env);
        });

        // Push an event from server
        if (pushSocket) {
          pushSocket.write(JSON.stringify({
            v: 1, id: "evt-1", ts: Date.now(),
            type: "event.order.placed",
            payload: { order_id: "o1", market_id: "m1", side: "buy", size: "10", price: "0.5" },
          }) + "\n");
        }

        // Wait for event to arrive
        await new Promise(resolve => setTimeout(resolve, 100));
        expect(received.length).toBe(1);
        expect(received[0].payload.order_id).toBe("o1");

        client.disconnect();
      } finally {
        pushServer.stop(true);
        try { unlinkSync(pushSock); } catch {}
      }
    });

    test("wildcard onEvent receives all event types", async () => {
      const wildSock = `/tmp/cex-test-wild-${Date.now()}.sock`;
      let wildSocket: any = null;

      const wildServer = Bun.listen({
        unix: wildSock,
        socket: {
          data(socket, raw: Buffer) {
            const text = raw.toString("utf8");
            for (const line of text.split("\n").filter(Boolean)) {
              try {
                const req = JSON.parse(line);
                if (req.type === "event.subscribe") {
                  socket.write(JSON.stringify({
                    v: 1, id: req.id, ts: Date.now(),
                    type: "event.subscribe.response",
                    payload: { status: "subscribed" },
                  }) + "\n");
                  wildSocket = socket;
                }
              } catch {}
            }
          },
          open() {},
          close() {},
          error() {},
        },
      });

      try {
        const client = new IPCClient({ socketPath: wildSock, requestTimeoutMs: 3000 });
        await client.connect();
        await client.subscribe();

        const received: any[] = [];
        client.onEvent("*", (env) => {
          received.push(env);
        });

        if (wildSocket) {
          wildSocket.write(JSON.stringify({
            v: 1, id: "evt-10", ts: Date.now(),
            type: "event.engine.halted",
            payload: { status: "halted", cancelled_orders: 3 },
          }) + "\n");
        }

        await new Promise(resolve => setTimeout(resolve, 100));
        expect(received.length).toBe(1);
        expect(received[0].type).toBe("event.engine.halted");

        client.disconnect();
      } finally {
        wildServer.stop(true);
        try { unlinkSync(wildSock); } catch {}
      }
    });

    test("onEvent logs handler errors", async () => {
      const errSock = `/tmp/cex-test-event-err-${Date.now()}.sock`;
      let errSocket: any = null;

      const errServer = Bun.listen({
        unix: errSock,
        socket: {
          data(socket, raw: Buffer) {
            const text = raw.toString("utf8");
            for (const line of text.split("\n").filter(Boolean)) {
              try {
                const req = JSON.parse(line);
                if (req.type === "event.subscribe") {
                  socket.write(JSON.stringify({
                    v: 1, id: req.id, ts: Date.now(),
                    type: "event.subscribe.response",
                    payload: { status: "subscribed" },
                  }) + "\n");
                  errSocket = socket;
                }
              } catch {}
            }
          },
          open() {},
          close() {},
          error() {},
        },
      });

      const originalConsoleError = console.error;
      const logs: string[] = [];
      console.error = (...args: unknown[]) => {
        logs.push(args.map(String).join(" "));
      };

      try {
        const client = new IPCClient({ socketPath: errSock, requestTimeoutMs: 3000 });
        await client.connect();
        await client.subscribe();

        client.onEvent("event.order.placed" as any, () => {
          throw new Error("handler boom");
        });

        if (errSocket) {
          errSocket.write(JSON.stringify({
            v: 1,
            id: "evt-err-1",
            ts: Date.now(),
            type: "event.order.placed",
            payload: { order_id: "o1" },
          }) + "\n");
        }

        await new Promise(resolve => setTimeout(resolve, 100));
        expect(logs.some(l => l.includes("handler boom") && l.includes("event.order.placed"))).toBe(true);

        client.disconnect();
      } finally {
        console.error = originalConsoleError;
        errServer.stop(true);
        try { unlinkSync(errSock); } catch {}
      }
    });
  });

  describe("Phase 5 control messages", () => {
    test("config.set request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("config.set", { key: "max_position_usd", value: "250" });
      expect(res.v).toBe(1);
      expect(res.type).toBe("config.set.response");

      client.disconnect();
    });

    test("pause request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("pause");
      expect(res.v).toBe(1);
      expect(res.type).toBe("pause.response");

      client.disconnect();
    });

    test("pnl.query request gets response", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.request("pnl.query", { window: "today" });
      expect(res.v).toBe(1);
      expect(res.type).toBe("pnl.response");

      client.disconnect();
    });

    test("configSet helper works", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.configSet("max_position_usd", "250");
      expect(res.v).toBe(1);
      expect(res.type).toBe("config.set.response");

      client.disconnect();
    });

    test("pause helper works", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.pause();
      expect(res.v).toBe(1);
      expect(res.type).toBe("pause.response");

      client.disconnect();
    });

    test("pnl helper works", async () => {
      const client = new IPCClient({
        socketPath: SOCK_PATH,
        requestTimeoutMs: 3000,
      });
      await client.connect();

      const res = await client.pnl("7d");
      expect(res.v).toBe(1);
      expect(res.type).toBe("pnl.response");

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
