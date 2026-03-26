import { test, expect, describe, beforeAll, afterAll } from "bun:test";
import { Database } from "bun:sqlite";
import { unlinkSync } from "node:fs";
import { resolve } from "node:path";

const DB_PATH = `/tmp/cex-test-${Date.now()}-${Math.random().toString(36).slice(2)}.db`;

// Set env BEFORE importing the db client module so getDB() picks it up
Bun.env.DB_PATH = DB_PATH;

let db: Database;

beforeAll(async () => {
  // Create a writable DB and run migrations
  db = new Database(DB_PATH, { create: true });
  const migrationPath = resolve(import.meta.dir, "../../db/migrations/001_initial.sql");
  const sql = await Bun.file(migrationPath).text();
  db.exec(sql);

  // Seed test data
  db.run(
    "INSERT INTO markets (id, symbol, base, quote) VALUES (?, ?, ?, ?)",
    ["m1", "BTC/USDT", "BTC", "USDT"],
  );

  db.run(
    "INSERT INTO positions (id, market_id, side, size, entry_price, status) VALUES (?, ?, ?, ?, ?, ?)",
    ["p1", "m1", "long", "1.0", "50000", "open"],
  );
  db.run(
    "INSERT INTO positions (id, market_id, side, size, entry_price, status) VALUES (?, ?, ?, ?, ?, ?)",
    ["p2", "m1", "short", "0.5", "51000", "closed"],
  );

  db.run(
    "INSERT INTO orders (id, market_id, type, side, size, status) VALUES (?, ?, ?, ?, ?, ?)",
    ["o1", "m1", "limit", "buy", "1.0", "pending"],
  );
  db.run(
    "INSERT INTO orders (id, market_id, type, side, size, status) VALUES (?, ?, ?, ?, ?, ?)",
    ["o2", "m1", "market", "sell", "0.5", "filled"],
  );

  db.run(
    "INSERT INTO logs (level, component, message) VALUES (?, ?, ?)",
    ["INFO", "engine", "started"],
  );
  db.run(
    "INSERT INTO logs (level, component, message) VALUES (?, ?, ?)",
    ["WARN", "ipc", "reconnecting"],
  );

  db.run(
    "INSERT INTO config_changes (id, key, new_value) VALUES (?, ?, ?)",
    ["c1", "max_position_size", "10"],
  );

  // Close the writable handle so the read-only client can open it
  db.close();
});

afterAll(() => {
  try {
    unlinkSync(DB_PATH);
  } catch {}
});

// Dynamic import AFTER env is set so the module-level cache uses our temp DB
// We need a fresh import to avoid the module cache with a different DB_PATH
let queryPositions: typeof import("../src/db/client.ts").queryPositions;
let queryOrders: typeof import("../src/db/client.ts").queryOrders;
let queryRecentLogs: typeof import("../src/db/client.ts").queryRecentLogs;
let queryConfig: typeof import("../src/db/client.ts").queryConfig;

beforeAll(async () => {
  const mod = await import("../src/db/client.ts");
  queryPositions = mod.queryPositions;
  queryOrders = mod.queryOrders;
  queryRecentLogs = mod.queryRecentLogs;
  queryConfig = mod.queryConfig;
});

describe("db client", () => {
  test("queryPositions returns array of open positions", () => {
    const rows = queryPositions();
    expect(Array.isArray(rows)).toBe(true);
    expect(rows.length).toBe(1); // only the "open" one
    expect((rows[0] as Record<string, unknown>).id).toBe("p1");
  });

  test("queryOrders returns non-filled/cancelled/rejected orders", () => {
    const rows = queryOrders();
    expect(Array.isArray(rows)).toBe(true);
    expect(rows.length).toBe(1); // only "pending" one, not "filled"
    expect((rows[0] as Record<string, unknown>).id).toBe("o1");
  });

  test("queryRecentLogs returns array of log entries", () => {
    const rows = queryRecentLogs();
    expect(Array.isArray(rows)).toBe(true);
    expect(rows.length).toBe(2);
  });

  test("queryRecentLogs respects limit parameter", () => {
    const rows = queryRecentLogs(1);
    expect(rows.length).toBe(1);
  });

  test("queryConfig returns config change entries", () => {
    const rows = queryConfig();
    expect(Array.isArray(rows)).toBe(true);
    expect(rows.length).toBe(1);
    expect((rows[0] as Record<string, unknown>).key).toBe("max_position_size");
  });
});
