import { test, expect, describe } from "bun:test";
import { makeRequest, IPC_VERSION } from "../src/ipc/types.ts";

describe("IPC_VERSION", () => {
  test("equals 1", () => {
    expect(IPC_VERSION).toBe(1);
  });
});

describe("makeRequest", () => {
  test("returns envelope with v=1, valid UUID id, ts as number, correct type, and payload", () => {
    const env = makeRequest("status");
    expect(env.v).toBe(1);
    expect(env.id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
    expect(typeof env.ts).toBe("number");
    expect(env.type).toBe("status");
    expect(env.payload).toEqual({});
  });

  test("without payload defaults to empty object", () => {
    const env = makeRequest("heartbeat");
    expect(env.payload).toEqual({});
  });

  test("with custom payload includes it", () => {
    const payload = { key: "value", nested: { a: 1 } };
    const env = makeRequest("config.get", payload);
    expect(env.payload).toEqual(payload);
  });

  test("each call produces a unique id", () => {
    const ids = new Set(Array.from({ length: 50 }, () => makeRequest("status").id));
    expect(ids.size).toBe(50);
  });

  test("ts is close to current time", () => {
    const before = Date.now();
    const env = makeRequest("status");
    const after = Date.now();
    expect(env.ts).toBeGreaterThanOrEqual(before);
    expect(env.ts).toBeLessThanOrEqual(after);
  });
});

describe("Phase 5 message types", () => {
  test("config.set request envelope", () => {
    const env = makeRequest("config.set", { key: "max_position_usd", value: "250" });
    expect(env.type).toBe("config.set");
    expect(env.payload).toEqual({ key: "max_position_usd", value: "250" });
  });

  test("pause request envelope", () => {
    const env = makeRequest("pause");
    expect(env.type).toBe("pause");
    expect(env.payload).toEqual({});
  });

  test("pnl.query request envelope", () => {
    const env = makeRequest("pnl.query", { window: "7d" });
    expect(env.type).toBe("pnl.query");
    expect(env.payload).toEqual({ window: "7d" });
  });
});
