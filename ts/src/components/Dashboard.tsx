import { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatUsd(val: string | number | undefined | null): string {
  if (val == null || val === "") return "—";
  const n = typeof val === "string" ? parseFloat(val) : val;
  if (isNaN(n)) return "—";
  return n.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2 });
}

function formatTs(ts: number | undefined | null): string {
  if (ts == null) return "—";
  // handle seconds vs milliseconds
  const ms = ts < 1e12 ? ts * 1000 : ts;
  return new Date(ms).toLocaleTimeString();
}

function truncate(str: string, len: number): string {
  if (str.length <= len) return str;
  return str.slice(0, len) + "…";
}

function pnlColor(val: string | number | undefined | null): string {
  if (val == null || val === "") return "";
  const n = typeof val === "string" ? parseFloat(val) : val;
  if (isNaN(n)) return "";
  if (n > 0) return "text-green-500";
  if (n < 0) return "text-red-500";
  return "";
}

// ---------------------------------------------------------------------------
// Polling hook
// ---------------------------------------------------------------------------

function useApi<T>(path: string, intervalMs = 2000) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    const fetcher = async () => {
      try {
        const res = await fetch(path);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const json = await res.json();
        if (mounted) {
          setData(json);
          setError(null);
        }
      } catch (e) {
        if (mounted) setError(e instanceof Error ? e.message : String(e));
      }
    };

    fetcher();
    const timer = setInterval(fetcher, intervalMs);
    return () => {
      mounted = false;
      clearInterval(timer);
    };
  }, [path, intervalMs]);

  return { data, error };
}

// ---------------------------------------------------------------------------
// Types (match API response shapes)
// ---------------------------------------------------------------------------

interface StatusData {
  engine: string;
  db: string;
  uptime_ms: number;
  usdc_balance?: string;
  total_exposure_usd?: string;
  open_orders_exposure_usd?: string;
  committed_capital_usd?: string;
  realized_pnl_today?: string;
  unrealized_pnl?: string;
}

interface PositionRow {
  market_id: string;
  side: string;
  size: string;
  entry_price: string;
  current_price?: string;
  unrealized_pnl?: string;
  status?: string;
}

interface OrderRow {
  id: string;
  market_id: string;
  side: string;
  size: string;
  price: string;
  order_type: string;
  status: string;
  created_at?: number;
}

interface LogRow {
  level: string;
  component: string;
  message: string;
  created_at: number;
}

interface MarketRow {
  id: string;
  question?: string;
  best_bid: number;
  best_ask: number;
  active: boolean;
  volume_24h: number;
  liquidity?: number;
}

interface PortfolioData {
  positions: PositionRow[];
  total_exposure_usd?: string;
  open_orders_exposure_usd?: string;
  committed_capital_usd?: string;
  unrealized_pnl?: string;
  realized_pnl_today?: string;
  usdc_balance?: string;
}

interface OrdersData {
  orders: OrderRow[];
  truncated?: boolean;
  skipped_count?: number;
}

interface LogsData {
  logs: LogRow[];
}

interface MarketsData {
  markets: MarketRow[];
}

// ---------------------------------------------------------------------------
// Level badge styling (FR-65)
// ---------------------------------------------------------------------------

function levelBadge(level: string) {
  const upper = level.toUpperCase();
  const styles: Record<string, string> = {
    ERROR: "bg-red-600 text-white",
    WARN: "bg-amber-500 text-black",
    INFO: "bg-blue-600 text-white",
    DEBUG: "bg-gray-600 text-gray-200",
  };
  return (
    <Badge className={`text-xs font-mono ${styles[upper] ?? "bg-gray-600 text-gray-200"}`}>
      {upper}
    </Badge>
  );
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

export function Dashboard() {
  const { data: status } = useApi<StatusData>("/api/status", 2000);
  const { data: portfolio } = useApi<PortfolioData>("/api/portfolio", 2000);
  const { data: orders } = useApi<OrdersData>("/api/orders", 2000);
  const { data: markets } = useApi<MarketsData>("/api/markets", 2000);
  const { data: logs } = useApi<LogsData>("/api/logs", 5000);

  // Derive KPI values — prefer portfolio snapshot fields, fall back to status
  const usdcBalance = portfolio?.usdc_balance ?? status?.usdc_balance;
  // "Total Exposure" = committed capital (filled positions + USDC locked in
  // open, unfilled orders). Falls back to position-only exposure for older
  // engines that don't emit the new fields.
  const totalExposure =
    portfolio?.committed_capital_usd ??
    status?.committed_capital_usd ??
    portfolio?.total_exposure_usd ??
    status?.total_exposure_usd;
  const positionsExposure = portfolio?.total_exposure_usd ?? status?.total_exposure_usd;
  const openOrdersExposure =
    portfolio?.open_orders_exposure_usd ?? status?.open_orders_exposure_usd;
  const dailyPnl = portfolio?.realized_pnl_today ?? status?.realized_pnl_today;
  const engineState = status?.engine ?? "unknown";

  const engineBadgeClass =
    engineState === "running"
      ? "bg-green-600 text-white"
      : engineState === "paused"
        ? "bg-yellow-500 text-black"
        : "bg-red-600 text-white";

  const positions = portfolio?.positions ?? [];
  const orderList = orders?.orders ?? [];
  const logList = logs?.logs ?? [];
  const marketList = markets?.markets ?? [];

  return (
    <div className="container mx-auto p-6 space-y-6">
      {/* Header */}
      <h1 className="text-3xl font-bold tracking-tight">CEX Engine Dashboard</h1>

      {/* FR-64: KPI Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">USDC Balance</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{formatUsd(usdcBalance)}</div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">Total Exposure</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{formatUsd(totalExposure)}</div>
            {(positionsExposure !== undefined || openOrdersExposure !== undefined) && (
              <div className="text-xs text-muted-foreground mt-1">
                positions {formatUsd(positionsExposure)} · open orders {formatUsd(openOrdersExposure)}
              </div>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">Daily P&L</CardTitle>
          </CardHeader>
          <CardContent>
            <div className={`text-2xl font-bold ${pnlColor(dailyPnl)}`}>{formatUsd(dailyPnl)}</div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">Engine Status</CardTitle>
          </CardHeader>
          <CardContent>
            <Badge className={`text-sm ${engineBadgeClass}`}>
              {engineState.charAt(0).toUpperCase() + engineState.slice(1)}
            </Badge>
            {status?.uptime_ms != null && (
              <div className="text-xs text-muted-foreground mt-1">
                Uptime: {(status.uptime_ms / 1000).toFixed(0)}s
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      {/* Positions & Orders */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Positions Table */}
        <Card>
          <CardHeader>
            <CardTitle>Positions</CardTitle>
          </CardHeader>
          <CardContent>
            {positions.length === 0 ? (
              <div className="text-muted-foreground text-sm py-4 text-center">No open positions</div>
            ) : (
              <div className="overflow-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b text-left text-muted-foreground">
                      <th className="py-2 pr-2">Market</th>
                      <th className="py-2 pr-2">Side</th>
                      <th className="py-2 pr-2 text-right">Size</th>
                      <th className="py-2 pr-2 text-right">Entry Price</th>
                      <th className="py-2 pr-2 text-right">Current Price</th>
                      <th className="py-2 text-right">Unrealized P&L</th>
                    </tr>
                  </thead>
                  <tbody>
                    {positions.map((p, i) => (
                      <tr key={i} className="border-b border-muted">
                        <td className="py-2 pr-2 font-mono text-xs">{truncate(p.market_id, 24)}</td>
                        <td className={`py-2 pr-2 font-semibold ${p.side === "long" ? "text-green-500" : "text-red-500"}`}>
                          {p.side}
                        </td>
                        <td className="py-2 pr-2 text-right font-mono">{p.size}</td>
                        <td className="py-2 pr-2 text-right font-mono">{formatUsd(p.entry_price)}</td>
                        <td className="py-2 pr-2 text-right font-mono">{p.current_price ? formatUsd(p.current_price) : "—"}</td>
                        <td className={`py-2 text-right font-mono ${pnlColor(p.unrealized_pnl)}`}>
                          {p.unrealized_pnl ? formatUsd(p.unrealized_pnl) : "—"}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </CardContent>
        </Card>

        {/* Active Orders Table */}
        <Card>
          <CardHeader>
            <CardTitle>Active Orders</CardTitle>
          </CardHeader>
          <CardContent>
            {orders?.truncated && (
              <div className="mb-3 rounded border border-amber-400 bg-amber-50 p-2 text-xs text-amber-900">
                Order list is incomplete. Skipped rows: {orders.skipped_count ?? 0}
              </div>
            )}
            {orderList.length === 0 ? (
              <div className="text-muted-foreground text-sm py-4 text-center">No active orders</div>
            ) : (
              <div className="overflow-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b text-left text-muted-foreground">
                      <th className="py-2 pr-2">ID</th>
                      <th className="py-2 pr-2">Market</th>
                      <th className="py-2 pr-2">Side</th>
                      <th className="py-2 pr-2">Type</th>
                      <th className="py-2 pr-2 text-right">Size</th>
                      <th className="py-2 pr-2 text-right">Price</th>
                      <th className="py-2">Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {orderList.map((o, i) => (
                      <tr key={i} className="border-b border-muted">
                        <td className="py-2 pr-2 font-mono text-xs">{truncate(o.id, 8)}</td>
                        <td className="py-2 pr-2 font-mono text-xs">{truncate(o.market_id, 20)}</td>
                        <td className={`py-2 pr-2 font-semibold ${o.side === "buy" || o.side === "long" ? "text-green-500" : "text-red-500"}`}>
                          {o.side}
                        </td>
                        <td className="py-2 pr-2">{o.order_type}</td>
                        <td className="py-2 pr-2 text-right font-mono">{o.size}</td>
                        <td className="py-2 pr-2 text-right font-mono">{formatUsd(o.price)}</td>
                        <td className="py-2">
                          <Badge variant="outline" className="text-xs">{o.status}</Badge>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      {/* FR-66: Market Tracker */}
      <Card>
        <CardHeader>
          <CardTitle>Market Tracker</CardTitle>
        </CardHeader>
        <CardContent>
          {marketList.length === 0 ? (
            <div className="text-muted-foreground text-sm py-4 text-center">No tracked markets</div>
          ) : (
            <div className="overflow-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-muted-foreground">
                    <th className="py-2 pr-2">Market</th>
                    <th className="py-2 pr-2 text-right">Best Bid</th>
                    <th className="py-2 pr-2 text-right">Best Ask</th>
                    <th className="py-2 pr-2 text-right">Mid Price</th>
                    <th className="py-2 pr-2 text-right">Spread</th>
                    <th className="py-2 pr-2 text-right">Volume 24h</th>
                    <th className="py-2">Active</th>
                  </tr>
                </thead>
                <tbody>
                  {marketList.map((m, i) => {
                    const mid = (m.best_bid + m.best_ask) / 2;
                    const spread = m.best_ask - m.best_bid;
                    return (
                      <tr key={i} className="border-b border-muted">
                        <td className="py-2 pr-2 text-xs">{truncate(m.question ?? m.id, 40)}</td>
                        <td className="py-2 pr-2 text-right font-mono">{m.best_bid.toFixed(4)}</td>
                        <td className="py-2 pr-2 text-right font-mono">{m.best_ask.toFixed(4)}</td>
                        <td className="py-2 pr-2 text-right font-mono">{mid.toFixed(4)}</td>
                        <td className="py-2 pr-2 text-right font-mono">{spread.toFixed(4)}</td>
                        <td className="py-2 pr-2 text-right font-mono">{m.volume_24h.toLocaleString()}</td>
                        <td className="py-2">
                          <Badge className={m.active ? "bg-green-600 text-white" : "bg-gray-600 text-gray-300"}>
                            {m.active ? "Yes" : "No"}
                          </Badge>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      {/* FR-65: System Log */}
      <Card>
        <CardHeader>
          <CardTitle>System Log</CardTitle>
        </CardHeader>
        <CardContent>
          {logList.length === 0 ? (
            <div className="text-muted-foreground text-sm py-4 text-center">No log entries</div>
          ) : (
            <div className="overflow-auto max-h-96 space-y-1">
              {logList.map((l, i) => (
                <div key={i} className="flex items-start gap-2 text-xs font-mono py-1 border-b border-muted">
                  <span className="text-muted-foreground whitespace-nowrap">{formatTs(l.created_at)}</span>
                  {levelBadge(l.level)}
                  <span className="text-muted-foreground whitespace-nowrap">[{l.component}]</span>
                  <span className="break-all">{l.message}</span>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
