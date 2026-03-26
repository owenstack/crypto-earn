import React, { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";

const API_KEY = "change-me-in-production"; // TODO: get from env in real app, hardcoded for phase 0 demo

function useApi<T>(path: string, intervalMs = 2000) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    const fetcher = async () => {
      try {
        const res = await fetch(path, {
          headers: { Authorization: `Bearer ${API_KEY}` }
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const json = await res.json();
        if (mounted) { setData(json); setError(null); }
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

export function Dashboard() {
  const { data: status } = useApi<any>("/api/status");
  const { data: portfolio } = useApi<any>("/api/portfolio");
  const { data: orders } = useApi<any>("/api/orders");

  return (
    <div className="container mx-auto p-6 space-y-6">
      <div className="flex justify-between items-center">
        <h1 className="text-3xl font-bold tracking-tight">CEX Engine Control</h1>
        <div className="flex gap-2">
          {status?.engine === "running" ? (
            <Badge variant="default" className="bg-green-600">Engine Online</Badge>
          ) : (
            <Badge variant="destructive">Engine Offline</Badge>
          )}
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">Engine Uptime</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">
              {status?.uptime_ms ? `${(status.uptime_ms / 1000).toFixed(1)}s` : "—"}
            </div>
          </CardContent>
        </Card>
        
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">Open Positions</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{portfolio?.positions?.length ?? 0}</div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">Pending Orders</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{orders?.orders?.length ?? 0}</div>
          </CardContent>
        </Card>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card className="col-span-1">
          <CardHeader>
            <CardTitle>Positions</CardTitle>
          </CardHeader>
          <CardContent>
            {portfolio?.positions?.length === 0 ? (
              <div className="text-muted-foreground text-sm py-4 text-center">No open positions</div>
            ) : (
              <pre className="text-xs bg-muted p-4 rounded-md overflow-auto max-h-[400px]">
                {JSON.stringify(portfolio?.positions, null, 2)}
              </pre>
            )}
          </CardContent>
        </Card>

        <Card className="col-span-1">
          <CardHeader>
            <CardTitle>Active Orders</CardTitle>
          </CardHeader>
          <CardContent>
            {orders?.orders?.length === 0 ? (
              <div className="text-muted-foreground text-sm py-4 text-center">No active orders</div>
            ) : (
              <pre className="text-xs bg-muted p-4 rounded-md overflow-auto max-h-[400px]">
                {JSON.stringify(orders?.orders, null, 2)}
              </pre>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
