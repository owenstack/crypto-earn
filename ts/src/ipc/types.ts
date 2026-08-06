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
  | "pnl.query"
  | "dry_run.analysis"
  | "reconcile.status"
  | "inventory.snapshot"
  | "config.validate"
  | "asset.mappings"
  | "funding.snapshot"
  | "arb.events";

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
  | "pnl.response"
  | "dry_run.analysis.response"
  | "reconcile.status.response"
  | "inventory.snapshot.response"
  | "config.validate.response"
  | "asset.mappings.response"
  | "funding.snapshot.response"
  | "arb.events.response";

export type EventMessageType =
  | "event.order.placed"
  | "event.order.filled"
  | "event.order.partially_filled"
  | "event.order.cancelled"
  | "event.order.rejected"
  | "event.risk.rejection"
  | "event.engine.halted" | "event.engine.resumed" | "event.engine.saturated" | "event.engine.capacity_restored"
  | "event.portfolio.updated"
  | "event.portfolio.stale"
  | "event.arb.triggered";
export interface EngineStateEventPayload {
  status: "halted" | "resumed" | "saturated" | "capacity_restored";
  cancelled_orders?: number;
}

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
export interface PortfolioPayload  {
  positions: unknown[];
  note?: string;
  /** Notional of *filled* positions (size * current_price). */
  total_exposure_usd?: string;
  /** Collateral committed by *open, unfilled* orders (size * limit_price). */
  open_orders_exposure_usd?: string;
  /** total_exposure_usd + open_orders_exposure_usd. */
  committed_capital_usd?: string;
  unrealized_pnl?: string | number;
  realized_pnl_today?: string;
  /**
   * @deprecated Phase 5 replaced this with `equity` for HL parity. The
   * Polymarket-era field is retained on the type for backwards compatibility
   * with older snapshots only; new payloads will not populate it.
   */
  usdc_balance?: string;
  /** Phase 5: HL account value from `clearinghouseState.marginSummary.accountValue`. */
  equity?: number;
  /** Phase 5: HL margin used in absolute units. */
  margin_used?: number;
  /** Phase 5: percentage of equity currently in use as margin. */
  margin_used_pct?: number;
  /** Phase 5: cumulative funding charged across all open positions. */
  funding_accrued?: number;
  /** Phase 5: unix epoch (s) when the snapshot was last refreshed. */
  snapshot_ts?: number;
  error?: string;
}

/** Phase 5: per-position payload used inside PortfolioPayload.positions. */
export interface HlPositionPayload {
  asset: string;
  side: "long" | "short";
  size: number;
  entry_price: number;
  mark_price: number;
  unrealized_pnl: number;
  funding_accrued: number;
  leverage: number;
}

/** Phase 5: response payload for `funding.snapshot`. */
export interface FundingSnapshotPayload {
  funding: Array<{
    asset: string;
    rate: number;
    next_payment_ts: number;
    recorded_at: number;
  }>;
}

/** Phase 5: response payload for `arb.events`. */
export interface ArbEventPayload {
  events: Array<{
    asset: string;
    binance_mid: number;
    hl_mid: number;
    delta_bps: number;
    order_id: string;
    realised_pnl: number;
    submit_ns: number;
    fill_ns: number;
    created_at: number;
  }>;
}

/** Phase 5: pushed when the portfolio tracker refreshes its snapshot. */
export interface PortfolioUpdatedEventPayload {
  equity: number;
  margin_used_pct: number;
  position_count: number;
  snapshot_ts: number;
}

/** Phase 5: pushed when the portfolio poll has failed N times in a row. */
export interface PortfolioStaleEventPayload {
  reason: string;
  last_success_ts: number;
}
export interface OrdersPayload     {
  orders: unknown[];
  note?: string;
  truncated?: boolean;
  skipped_count?: number;
}
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
  positions: Array<PositionInfo | HlPositionPayload>;
  total_exposure_usd?: string;
  open_orders_exposure_usd?: string;
  committed_capital_usd?: string;
  unrealized_pnl?: string | number;
  realized_pnl_today?: string;
  /** @deprecated Legacy snapshots only. Prefer `equity`. */
  usdc_balance?: string;
  equity?: number;
  margin_used?: number;
  margin_used_pct?: number;
  funding_accrued?: number;
  snapshot_ts?: number;
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
export type StrategyName = "market_making" | "cex_dex_arb";

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
  active_order_overflow_count: number;
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
  status: "halted" | "resumed" | "saturated" | "capacity_restored";
  cancelled_orders?: number;
}

// Phase 2: Fill detection payloads
export interface OrderFilledEventPayload {
  order_id: string;
  market_id: string;
  side: string;
  fill_size: string;
  fill_price: string;
  realized_pnl: string;
}

export interface OrderPartiallyFilledEventPayload {
  order_id: string;
  market_id: string;
  side: string;
  fill_size: string;
  fill_price: string;
  remaining_size: string;
}

export interface ReconcileStatusPayload {
  adopted: number;
  closed: number;
  unchanged: number;
  remote_checked?: boolean;
  error?: string;
  status: "pending" | "complete" | "error";
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

export interface DryRunAnalysisResponsePayload {
  total_signals: number;
  persistent_signals: number;
  persistence_pct: number;
  optimistic_pnl: number;
  pessimistic_pnl: number;
  paper_entry_lookahead_seconds: number;
  paper_max_hold_seconds: number;
  paper_fee_bps_per_side: number;
  paper_submitted_orders: number;
  paper_filled_trades: number;
  paper_unfilled_signals: number;
  paper_fill_rate_pct: number;
  paper_winning_trades: number;
  paper_losing_trades: number;
  paper_win_rate_pct: number;
  paper_net_pnl: number;
  paper_avg_pnl_per_trade: number;
  paper_expectancy_per_order: number;
  paper_profit_factor: number;
  paper_max_drawdown: number;
  paper_avg_hold_seconds: number;
  paper_avg_fill_latency_seconds: number;
  paper_fallback_exit_marks: number;
  diagnosis: "no_data" | "no_fills_detected" | "paper_loss" | "fill_rate_too_low" | "paper_viable";
}

export interface ConfigValidateResponsePayload {
  mode: { valid: boolean; value: string };
  hl_api_base: { valid: boolean; value: string };
  hl_signer: { valid: boolean; value: string };
  hl_symbols: { valid: boolean; value: string };
  binance_symbols: { valid: boolean; value: string };
  market_data: { valid: boolean; value: string };
  cex_dex_arb: { valid: boolean; value: string };
  reconciliation: { valid: boolean; value: string };
}

export interface AssetMappingInfo {
  source_id: string;
  market_id: string;
  symbol?: string;
  base?: string;
  quote?: string;
  asset_index?: number;
  base_asset?: string;
  max_leverage?: number;
  confidence: number;
  match_method: string;
  updated_at: number;
}

export interface AssetMappingsResponsePayload {
  mappings: AssetMappingInfo[];
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
