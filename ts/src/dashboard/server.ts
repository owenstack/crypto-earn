/**
 * Dashboard HTTP routes (Bun.serve-compatible route handlers).
 * All /api/* routes require Bearer auth. Frontend is served via HTML import.
 */
import type { IPCClient } from "../ipc/client";
import { queryPositions, queryOrders, queryRecentLogs } from "../db/client";

const DASHBOARD_SECRET = Bun.env.DASHBOARD_SECRET ?? "";

// Frontend intentionally sends no Authorization header; auth is enforced here.
// Operators should access through a trusted layer that injects the bearer token.
function bearerAuth(req: Request): boolean {
  const auth = req.headers.get("Authorization") ?? "";
  return auth === `Bearer ${DASHBOARD_SECRET}` && DASHBOARD_SECRET.length > 0;
}

function json(data: unknown, status = 200) {
  return Response.json(data, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

function unauthorized() {
  return json({ error: "Unauthorized" }, 401);
}

export function dashboardRoutes(ipc: IPCClient) {
  return {
    "/api/status": {
      async GET(req: Request) {
        if (!bearerAuth(req)) return unauthorized();
        if (!ipc.connected) return json({ engine: "offline", db: "unknown", uptime_ms: 0 });
        const res = await ipc.request("status").catch(() => null);
        return json(res?.payload ?? { engine: "offline" });
      },
    },

    "/api/portfolio": {
      async GET(req: Request) {
        if (!bearerAuth(req)) return unauthorized();
        // Prefer SQLite snapshot for dashboard (avoids IPC round-trip for tables)
        const positions = queryPositions();
        return json({ positions });
      },
    },

    "/api/orders": {
      async GET(req: Request) {
        if (!bearerAuth(req)) return unauthorized();
        const orders = queryOrders();
        return json({ orders });
      },
    },

    "/api/logs": {
      async GET(req: Request) {
        if (!bearerAuth(req)) return unauthorized();
        const logs = queryRecentLogs(200);
        return json({ logs });
      },
    },

    "/api/heartbeat": {
      async GET(req: Request) {
        if (!bearerAuth(req)) return unauthorized();
        if (!ipc.connected) return json({ status: "offline" });
        const res = await ipc.request("heartbeat").catch(() => null);
        return json(res?.payload ?? { status: "offline" });
      },
    },

    "/api/config": {
      async GET(req: Request) {
        if (!bearerAuth(req)) return unauthorized();
        if (!ipc.connected) return json({ config: {} });
        const res = await ipc.request("config.get").catch(() => null);
        return json(res?.payload ?? { config: {} });
      },
    },

    "/api/markets": {
      async GET(req: Request) {
        if (!bearerAuth(req)) return unauthorized();
        if (!ipc.connected) return json({ markets: [] });
        const res = await ipc.request("market.list").catch(() => null);
        return json(res?.payload ?? { markets: [] });
      },
    },

    "/api/dry-run-analysis": {
      async GET(req: Request) {
        if (!bearerAuth(req)) return unauthorized();
        if (!ipc.connected) return json({ diagnosis: "offline" }, 503);
        const res = await ipc.request("dry_run.analysis").catch(() => null);
        return json(res?.payload ?? { diagnosis: "unavailable" }, res ? 200 : 502);
      },
    },
  } as const;
}
