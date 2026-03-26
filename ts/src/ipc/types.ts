/** Phase-0 IPC envelope contract (must match zig/src/ipc_types.zig). */

export const IPC_VERSION = 1 as const;

export type RequestMessageType =
  | "heartbeat"
  | "status"
  | "portfolio"
  | "orders"
  | "config.get"
  | "logs";

export type ResponseMessageType =
  | "heartbeat.response"
  | "status.response"
  | "portfolio.response"
  | "orders.response"
  | "config.get.response"
  | "logs.response"
  | "error.response";

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
