import { test, expect, describe, beforeAll, afterAll } from "bun:test";
import { Database } from "bun:sqlite";
import { unlinkSync } from "node:fs";
import { resolve } from "node:path";

const DB_PATH = `/tmp/cex-dash-test-${Date.now()}-${Math.random().toString(36).slice(2)}.db`;
const SECRET = "test-secret-token";

// Set env BEFORE importing dashboard module
Bun.env.DB_PATH = DB_PATH;
Bun.env.DASHBOARD_SECRET = SECRET;

let db: Database;

beforeAll(async () => {
  db = new Database(DB_PATH, { create: true });
  const migrationPath = resolve(import.meta.dir, "../../db/migrations/001_initial.sql");
  const sql = await Bun.file(migrationPath).text();
  db.exec(sql);

  // Seed data
  db.run("INSERT INTO markets (id, symbol, base, quote) VALUES (?, ?, ?, ?)", [
    "m1", "BTC/USDT", "BTC", "USDT",
  ]);
  db.run(
    "INSERT INTO positions (id, market_id, side, size, entry_price, status) VALUES (?, ?, ?, ?, ?, ?)",
    ["p1", "m1", "long", "1.0", "50000", "open"],
  );
  db.run(
    "INSERT INTO orders (id, market_id, type, side, size, status) VALUES (?, ?, ?, ?, ?, ?)",
    ["o1", "m1", "limit", "buy", "1.0", "pending"],
  );
  db.run("INSERT INTO logs (level, component, message) VALUES (?, ?, ?)", [
    "INFO", "engine", "test log",
  ]);

  db.close();
});

afterAll(() => {
  try { unlinkSync(DB_PATH); } catch {}
});

// Dynamic import after env setup
let dashboardRoutes: typeof import("../src/dashboard/server.ts").dashboardRoutes;

beforeAll(async () => {
  const mod = await import("../src/dashboard/server.ts");
  dashboardRoutes = mod.dashboardRoutes;
});

function makeIpcMock(connected = true) {
  return {
    connected,
    async request(_type: string) {
      return {
        v: 1 as const,
        id: "mock-id",
        ts: Date.now(),
        type: `${_type}.response`,
        payload: { engine: "running", db: "ok", uptime_ms: 12345, status: "ok", config: { key: "val" } },
      };
    },
    connect: async () => {},
    disconnect: () => {},
  };
}

function authedReq(path: string) {
  return new Request(`http://localhost${path}`, {
    headers: { Authorization: `Bearer ${SECRET}` },
  });
}

function unauthedReq(path: string) {
  return new Request(`http://localhost${path}`);
}

function badAuthReq(path: string) {
  return new Request(`http://localhost${path}`, {
    headers: { Authorization: "Bearer wrong-token" },
  });
}

describe("dashboardRoutes", () => {
  test("returns route objects for all expected paths", () => {
    const routes = dashboardRoutes(makeIpcMock() as any);
    const paths = Object.keys(routes);
    expect(paths).toContain("/api/status");
    expect(paths).toContain("/api/portfolio");
    expect(paths).toContain("/api/orders");
    expect(paths).toContain("/api/logs");
    expect(paths).toContain("/api/heartbeat");
    expect(paths).toContain("/api/config");
  });

  describe("Bearer auth", () => {
    test("request without Authorization header returns 401", async () => {
      const routes = dashboardRoutes(makeIpcMock() as any);
      const res = await routes["/api/status"].GET(unauthedReq("/api/status"));
      expect(res.status).toBe(401);
      const body = await res.json();
      expect(body.error).toBe("Unauthorized");
    });

    test("request with wrong token returns 401", async () => {
      const routes = dashboardRoutes(makeIpcMock() as any);
      const res = await routes["/api/status"].GET(badAuthReq("/api/status"));
      expect(res.status).toBe(401);
    });

    test("authorized request returns 200", async () => {
      const routes = dashboardRoutes(makeIpcMock() as any);
      const res = await routes["/api/status"].GET(authedReq("/api/status"));
      expect(res.status).toBe(200);
    });
  });

  describe("IPC-dependent routes", () => {
    test("/api/status returns engine status when connected", async () => {
      const routes = dashboardRoutes(makeIpcMock(true) as any);
      const res = await routes["/api/status"].GET(authedReq("/api/status"));
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.engine).toBe("running");
    });

    test("/api/status returns offline when IPC disconnected", async () => {
      const routes = dashboardRoutes(makeIpcMock(false) as any);
      const res = await routes["/api/status"].GET(authedReq("/api/status"));
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.engine).toBe("offline");
    });

    test("/api/heartbeat returns payload when connected", async () => {
      const routes = dashboardRoutes(makeIpcMock(true) as any);
      const res = await routes["/api/heartbeat"].GET(authedReq("/api/heartbeat"));
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.status).toBe("ok");
    });

    test("/api/heartbeat returns offline when disconnected", async () => {
      const routes = dashboardRoutes(makeIpcMock(false) as any);
      const res = await routes["/api/heartbeat"].GET(authedReq("/api/heartbeat"));
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.status).toBe("offline");
    });

    test("/api/config returns config when connected", async () => {
      const routes = dashboardRoutes(makeIpcMock(true) as any);
      const res = await routes["/api/config"].GET(authedReq("/api/config"));
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.config).toBeDefined();
    });

    test("/api/config returns empty config when disconnected", async () => {
      const routes = dashboardRoutes(makeIpcMock(false) as any);
      const res = await routes["/api/config"].GET(authedReq("/api/config"));
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.config).toEqual({});
    });
  });

  describe("Read-only enforcement", () => {
    test("no routes expose POST, PUT, DELETE, or PATCH methods", () => {
      const routes = dashboardRoutes(makeIpcMock() as any);
      for (const [path, handlers] of Object.entries(routes)) {
        const methods = Object.keys(handlers as Record<string, unknown>);
        for (const method of methods) {
          expect(["GET"]).toContain(method);
        }
      }
    });
  });

  describe("DB-dependent routes", () => {
    test("/api/portfolio returns positions from DB", async () => {
      const routes = dashboardRoutes(makeIpcMock() as any);
      const res = await routes["/api/portfolio"].GET(authedReq("/api/portfolio"));
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(Array.isArray(body.positions)).toBe(true);
      expect(body.positions.length).toBeGreaterThanOrEqual(1);
    });

    test("/api/orders returns orders from DB", async () => {
      const routes = dashboardRoutes(makeIpcMock() as any);
      const res = await routes["/api/orders"].GET(authedReq("/api/orders"));
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(Array.isArray(body.orders)).toBe(true);
    });

    test("/api/logs returns logs from DB", async () => {
      const routes = dashboardRoutes(makeIpcMock() as any);
      const res = await routes["/api/logs"].GET(authedReq("/api/logs"));
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(Array.isArray(body.logs)).toBe(true);
    });
  });
});
