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
  | "orderbook.snapshot"
  | "order.place"
  | "order.cancel"
  | "order.cancel_all"
  | "halt"
  | "resume"
  | "strategy.enable"
  | "strategy.disable"
  | "strategy.list"
  | "event.subscribe"
  | "event.unsubscribe"
  | "config.set"
  | "pause"
  | "pnl.query";

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
  | "price.update"
  | "risk.check.response"
  | "order.event"
  | "portfolio.snapshot.response"
  | "orders.open.response"
  | "order.place.response"
  | "order.cancel.response"
  | "order.cancel_all.response"
  | "halt.response"
  | "resume.response"
  | "strategy.enable.response"
  | "strategy.disable.response"
  | "strategy.list.response"
  | "strategy.signal.event"
  | "event.subscribe.response"
  | "event.unsubscribe.response"
  | "config.set.response"
  | "pause.response"
  | "pnl.response";

export type EventMessageType =
  | "event.order.placed"
  | "event.order.filled"
  | "event.order.partially_filled"
  | "event.order.cancelled"
  | "event.order.rejected"
  | "event.risk.rejection"
  | "event.engine.halted"
  | "event.engine.resumed";

export type MessageType = RequestMessageType | ResponseMessageType | EventMessageType;

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

// Phase 2: Order/Risk payloads
export interface OrderPlaceRequestPayload {
  market_id: string;
  side: "buy" | "sell";
  size: string;
  price: string;
  order_type: "limit" | "market";
}

export interface OrderPlacePayload {
  market_id: string;
  side: "buy" | "sell";
  size: string;
  price: string;
  order_type: "limit" | "market" | "GTC" | "FOK";
}

export interface OrderCancelPayload {
  order_id: string;
}

export interface OrderPlaceResponsePayload {
  order_id: string;
  status: string;
}

export interface OrderCancelResponsePayload {
  order_id: string;
  status: string;
}

export interface OrderCancelAllResponsePayload {
  cancelled_count: number;
}

export interface RiskCheckResponsePayload {
  passed: boolean;
  check_name?: string;
  reason?: string;
  limit_value?: string;
  actual_value?: string;
}

export interface OrderEventPayload {
  order_id: string;
  market_id: string;
  event_type: "placed" | "filled" | "partially_filled" | "cancelled" | "rejected";
  side: string;
  size: string;
  price: string;
  reason?: string;
}

export interface PortfolioSnapshotPayload {
  positions: PositionInfo[];
  total_exposure_usd: string;
  unrealized_pnl: string;
  realized_pnl_today: string;
  usdc_balance: string;
}

export interface PositionInfo {
  market_id: string;
  side: "long" | "short";
  size: string;
  entry_price: string;
  current_price: string;
  unrealized_pnl: string;
}

export interface OrdersOpenPayload {
  orders: OpenOrderInfo[];
}

export interface OpenOrderInfo {
  id: string;
  market_id: string;
  side: string;
  size: string;
  price: string;
  order_type: string;
  status: string;
  created_at: number;
}

export interface HaltResponsePayload {
  status: "halted";
  cancelled_orders: number;
}

export interface ResumeResponsePayload {
  status: "resumed";
}

// Phase 3: Strategy payloads
export type StrategyName = "news_repricing" | "liquidity_provision";

export interface StrategyEnableDisablePayload {
  name: StrategyName;
}

export interface StrategyEnableResponsePayload {
  name: string;
  enabled: true;
}

export interface StrategyDisableResponsePayload {
  name: string;
  enabled: false;
}

export interface StrategyStatsInfo {
  signals_emitted: number;
  orders_accepted: number;
  orders_rejected: number;
  cancels: number;
  realized_pnl_estimate: number;
}

export interface StrategyInfo {
  name: string;
  enabled: boolean;
  stats: StrategyStatsInfo;
}

export interface StrategyListResponsePayload {
  strategies: StrategyInfo[];
}

export interface StrategySignalEventPayload {
  strategy: string;
  market_id: string;
  direction: "buy" | "sell";
  price: number;
  size: number;
  confidence: number;
}

// Phase 4: Event subscription payloads
export interface EventSubscribeResponsePayload {
  status: "subscribed";
}

export interface EventUnsubscribeResponsePayload {
  status: "unsubscribed";
}

export interface EventEnvelope<P = unknown> {
  v: typeof IPC_VERSION;
  id: string;       // server-generated event id (evt-NNN)
  ts: number;
  type: EventMessageType;
  payload: P;
}

export interface OrderEventPushPayload {
  order_id: string;
  market_id: string;
  side: string;
  size: string;
  price: string;
  order_type?: string;
  reason?: string;
}

export interface RiskRejectionEventPayload {
  order_id: string;
  market_id: string;
  side: string;
  check_name: string;
  reason: string;
  limit_value: string;
  actual_value: string;
}

export interface EngineStateEventPayload {
  status: "halted" | "resumed";
  cancelled_orders?: number;
}

// Phase 5: Config/Pause/P&L payloads
export interface ConfigSetRequestPayload {
  key: string;
  value: string;
}

export interface ConfigSetResponsePayload {
  key: string;
  old_value: string | null;
  new_value: string;
}

export interface PauseRequestPayload {
  action: "pause";
}

export interface PauseResponsePayload {
  status: "paused";
}

export type PnlWindow = "today" | "7d" | "30d" | "all";

export interface PnlQueryRequestPayload {
  window: PnlWindow;
}

export interface PnlResponsePayload {
  window: string;
  realized_pnl: string;
  unrealized_pnl: string;
  win_count: number;
  loss_count: number;
  avg_win: string;
  avg_loss: string;
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
