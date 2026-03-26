/** Phase-0 IPC envelope contract (must match zig/src/ipc_types.zig). */

export const IPC_VERSION = 1 as const;

export type RequestMessageType =
  | "heartbeat"
  | "status"
  | "portfolio"
  | "orders"
  | "config.get"
  | "logs"
  | "market.list"
  | "orderbook.snapshot";

export type ResponseMessageType =
  | "heartbeat.response"
  | "status.response"
  | "portfolio.response"
  | "orders.response"
  | "config.get.response"
  | "logs.response"
  | "error.response"
  | "market.list.response"
  | "orderbook.snapshot.response"
  | "price.update";

export type MessageType = RequestMessageType | ResponseMessageType;

export interface Envelope<P = unknown> {
  v: typeof IPC_VERSION;
  id: string;
  ts: number;
  type: MessageType;
  payload: P;
}

export interface HeartbeatPayload  { status: "ok"; uptime_ms: number }
export interface StatusPayload     { engine: string; db: string; uptime_ms: number }
export interface PortfolioPayload  { positions: unknown[]; note?: string }
export interface OrdersPayload     { orders: unknown[]; note?: string }
export interface ConfigPayload     { config: Record<string, string>; note?: string }
export interface LogsPayload       { logs: LogEntry[] }
export interface ErrorPayload      { error: string }

// Phase 1: Market data payloads
export interface MarketListPayload {
  markets: MarketInfo[];
}

export interface MarketInfo {
  id: string;
  question: string;
  condition_id: string;
  slug: string;
  end_date: string;
  volume_24h: number;
  liquidity: number;
  clob_token_ids: string;
  outcome_prices: string;
  outcomes: string;
  best_bid: number;
  best_ask: number;
  active: boolean;
  accepting_orders: boolean;
}

export interface OrderbookPayload {
  market: string;
  asset_id: string;
  best_bid: string;
  best_ask: string;
  mid_price: number;
  bids_json: string;
  asks_json: string;
  last_trade_price: string;
  tick_size: string;
  timestamp: string;
}

export interface PriceUpdatePayload {
  market: string;
  asset_id: string;
  best_bid: string;
  best_ask: string;
  mid_price: number;
  timestamp: string;
}

export interface LogEntry {
  ts: number;
  level: "DEBUG" | "INFO" | "WARN" | "ERROR";
  component: string;
  msg: string;
}

/** Build a request envelope with a random correlation ID. */
export function makeRequest(type: RequestMessageType): Envelope<Record<string, never>>;
export function makeRequest<P>(type: RequestMessageType, payload: P): Envelope<P>;
export function makeRequest<P>(type: RequestMessageType, payload?: P): Envelope<P | Record<string, never>> {
  return {
    v: IPC_VERSION,
    id: crypto.randomUUID(),
    ts: Date.now(),
    type,
    payload: payload ?? {},
  };
}
