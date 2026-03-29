/**
 * UNIX socket IPC client with line-buffered JSON framing,
 * reconnect/back-off, per-request timeout, and correlation tracking.
 */
import type { Envelope, RequestMessageType, EventMessageType, OrderPlaceResponsePayload, OrderCancelResponsePayload, OrderCancelAllResponsePayload, HaltResponsePayload, ResumeResponsePayload, StrategyListResponsePayload, StrategyEnableResponsePayload, StrategyDisableResponsePayload, StrategyEnableDisablePayload, StrategyName, EventSubscribeResponsePayload, EventUnsubscribeResponsePayload } from "./types";
import { makeRequest } from "./types";
import type { OrderPlaceRequestPayload, OrderCancelPayload } from "./types";

export interface IPCClientOptions {
  socketPath?: string;
  connectTimeoutMs?: number;
  requestTimeoutMs?: number;
  maxReconnectDelayMs?: number;
  maxInitialAttempts?: number;
}

type Resolver = (envelope: Envelope) => void;
type Rejector  = (err: Error) => void;
type EventHandler = (envelope: Envelope) => void;

interface InitialConnectState {
  startedAt: number;
  attempts: number;
  settled: boolean;
}

export class IPCClient {
  private socketPath: string;
  private connectTimeoutMs: number;
  private requestTimeoutMs: number;
  private maxReconnectDelayMs: number;
  private maxInitialAttempts: number;

  private socket: ReturnType<typeof Bun.connect> | null = null;
  private pending = new Map<string, { resolve: Resolver; reject: Rejector; timer: Timer }>();
  private lineBuffer = "";
  private reconnectDelay = 250;
  private _connected = false;
  private eventHandlers = new Map<string, Set<EventHandler>>();
  private _subscribed = false;
  private _autoSubscribe = false;

  constructor(opts: IPCClientOptions = {}) {
    this.socketPath = opts.socketPath ?? Bun.env.IPC_SOCKET ?? "/tmp/cex-engine.sock";
    this.connectTimeoutMs = opts.connectTimeoutMs ?? 10_000;
    this.requestTimeoutMs = opts.requestTimeoutMs ?? 5_000;
    this.maxReconnectDelayMs = opts.maxReconnectDelayMs ?? 30_000;
    this.maxInitialAttempts = opts.maxInitialAttempts ?? 8;
  }

  get connected() { return this._connected; }

  /** Connect and keep reconnecting in the background. */
  async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const initial: InitialConnectState = {
        startedAt: Date.now(),
        attempts: 0,
        settled: false,
      };

      const onFirst = () => {
        if (initial.settled) return;
        initial.settled = true;
        resolve();
      };

      const onFirstErr = (err: Error) => {
        if (initial.settled) return;
        initial.settled = true;
        reject(err);
      };

      this._doConnect(onFirst, onFirstErr, initial);
    });
  }

  private _doConnect(onFirst?: () => void, onFirstErr?: (e: Error) => void, initial?: InitialConnectState) {
    if (initial?.settled) return;

    if (initial) {
      initial.attempts += 1;
      if (this._initialConnectExpired(initial)) {
        onFirstErr?.(this._initialConnectError(initial));
        return;
      }
    }

    const self = this;
    Bun.connect({
      unix: this.socketPath,
      socket: {
        open(sock) {
          self.socket = sock as unknown as ReturnType<typeof Bun.connect>;
          self._connected = true;
          self.reconnectDelay = 250;
          console.error(JSON.stringify({ ts: Date.now(), level: "INFO", component: "ipc", msg: `connected to ${self.socketPath}` }));
          onFirst?.();
          onFirst = undefined;
          onFirstErr = undefined;
          // Auto-resubscribe to events on reconnect
          if (self._autoSubscribe && !self._subscribed) {
            self.subscribe().catch((err) => {
              console.error(JSON.stringify({ ts: Date.now(), level: "WARN", component: "ipc", msg: `event resubscribe failed: ${err.message}` }));
            });
          }
        },
        data(_sock, raw: Buffer) {
          self.lineBuffer += raw.toString("utf8");
          const lines = self.lineBuffer.split("\n");
          self.lineBuffer = lines.pop() ?? "";
          for (const line of lines) {
            if (!line.trim()) continue;
            try {
              const env = JSON.parse(line) as Envelope;
              const pending = self.pending.get(env.id);
              if (pending) {
                clearTimeout(pending.timer);
                self.pending.delete(env.id);
                pending.resolve(env);
              } else if (typeof env.type === "string" && env.type.startsWith("event.") && !env.type.endsWith(".response")) {
                // Non-correlated event push — route to event handlers
                self._dispatchEvent(env);
              }
            } catch { /* malformed – ignore */ }
          }
        },
        close() {
          self._connected = false;
          self._subscribed = false;
          self.socket = null;
          // Reject all in-flight requests
          for (const [id, p] of self.pending) {
            clearTimeout(p.timer);
            p.reject(new Error("IPC connection closed"));
            self.pending.delete(id);
          }
          // Back-off reconnect
          console.error(JSON.stringify({ ts: Date.now(), level: "WARN", component: "ipc", msg: `disconnected, reconnecting in ${self.reconnectDelay}ms` }));
          if (initial && !initial.settled) {
            if (!self._initialConnectExpired(initial)) {
              setTimeout(() => self._doConnect(onFirst, onFirstErr, initial), self.reconnectDelay);
            } else {
              onFirstErr?.(self._initialConnectError(initial));
            }
          } else {
            setTimeout(() => self._doConnect(), self.reconnectDelay);
          }
          self.reconnectDelay = Math.min(self.reconnectDelay * 2, self.maxReconnectDelayMs);
        },
        error(_sock, err) {
          console.error(JSON.stringify({ ts: Date.now(), level: "ERROR", component: "ipc", msg: String(err) }));
          if (initial && !initial.settled && self._initialConnectExpired(initial)) {
            onFirstErr?.(self._initialConnectError(initial, err));
          }
        },
      },
    }).catch((err: Error) => {
      console.error(JSON.stringify({ ts: Date.now(), level: "WARN", component: "ipc", msg: `connect failed: ${err.message}, retry in ${self.reconnectDelay}ms` }));
      if (initial && !initial.settled) {
        if (self._initialConnectExpired(initial)) {
          onFirstErr?.(self._initialConnectError(initial, err));
          return;
        }
        setTimeout(() => self._doConnect(onFirst, onFirstErr, initial), self.reconnectDelay);
      } else {
        setTimeout(() => self._doConnect(onFirst, onFirstErr), self.reconnectDelay);
      }
      self.reconnectDelay = Math.min(self.reconnectDelay * 2, self.maxReconnectDelayMs);
    });
  }

  private _initialConnectExpired(state: InitialConnectState): boolean {
    const elapsed = Date.now() - state.startedAt;
    return elapsed >= this.connectTimeoutMs || state.attempts > this.maxInitialAttempts;
  }

  private _initialConnectError(state: InitialConnectState, cause?: unknown): Error {
    const elapsed = Date.now() - state.startedAt;
    const details = cause instanceof Error ? ` Last error: ${cause.message}.` : "";
    return new Error(
      `Initial IPC connection failed after ${state.attempts} attempts and ${elapsed}ms ` +
      `(limits: maxInitialAttempts=${this.maxInitialAttempts}, connectTimeoutMs=${this.connectTimeoutMs}).${details}`,
    );
  }

  /** Send a typed request and await the correlated response. */
  async request<RES = unknown>(type: RequestMessageType): Promise<Envelope<RES>>;
  async request<REQ, RES = unknown>(type: RequestMessageType, payload: REQ): Promise<Envelope<RES>>;
  async request<REQ>(type: RequestMessageType, payload?: REQ): Promise<Envelope<unknown>> {
    if (!this.socket || !this._connected) throw new Error("IPC not connected");

    const req = payload === undefined ? makeRequest(type) : makeRequest(type, payload);
    const line = JSON.stringify(req) + "\n";

    return new Promise<Envelope<unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(req.id);
        reject(new Error(`IPC timeout: ${type}`));
      }, this.requestTimeoutMs);

      this.pending.set(req.id, {
        resolve: resolve as Resolver,
        reject,
        timer,
      });

      (this.socket as unknown as { write(d: string): void }).write(line);
    });
  }

  disconnect() {
    (this.socket as unknown as { end(): void } | null)?.end();
    this._connected = false;
  }

  // Phase 2 typed helpers
  async placeOrder(
    market_id: string,
    side: "buy" | "sell",
    size: string,
    price: string,
    order_type: OrderPlaceRequestPayload["order_type"] = "limit",
  ) {
    return this.request<OrderPlaceRequestPayload, OrderPlaceResponsePayload>("order.place", {
      market_id,
      side,
      size,
      price,
      order_type,
    });
  }

  async cancelOrder(order_id: string) {
    return this.request<OrderCancelPayload, OrderCancelResponsePayload>("order.cancel", { order_id });
  }

  async cancelAllOrders() {
    return this.request<OrderCancelAllResponsePayload>("order.cancel_all");
  }

  async halt() {
    return this.request<HaltResponsePayload>("halt");
  }

  async resume() {
    return this.request<ResumeResponsePayload>("resume");
  }

  // Phase 3 strategy helpers
  async strategyList() {
    return this.request<StrategyListResponsePayload>("strategy.list");
  }

  async strategyEnable(name: StrategyName) {
    return this.request<StrategyEnableDisablePayload, StrategyEnableResponsePayload>(
      "strategy.enable",
      { name },
    );
  }

  async strategyDisable(name: StrategyName) {
    return this.request<StrategyEnableDisablePayload, StrategyDisableResponsePayload>(
      "strategy.disable",
      { name },
    );
  }

  /** Subscribe to event stream from Zig engine. */
  async subscribe(): Promise<void> {
    const res = await this.request<EventSubscribeResponsePayload>("event.subscribe");
    if (res.payload.status === "subscribed") {
      this._subscribed = true;
      this._autoSubscribe = true;
    } else {
      throw new Error(`Subscription failed: ${res.payload.status}`);
    }
  }

  /** Unsubscribe from event stream. */
  async unsubscribe(): Promise<void> {
    await this.request<EventUnsubscribeResponsePayload>("event.unsubscribe");
    this._subscribed = false;
    this._autoSubscribe = false;
  }

  /** Register a handler for a specific event type or '*' for all events. */
  onEvent(eventType: EventMessageType | "*", handler: EventHandler): () => void {
    if (!this.eventHandlers.has(eventType)) {
      this.eventHandlers.set(eventType, new Set());
    }
    this.eventHandlers.get(eventType)!.add(handler);
    return () => {
      this.eventHandlers.get(eventType)?.delete(handler);
    };
  }

  /** Remove all handlers for a specific event type. */
  offEvent(eventType: EventMessageType | "*"): void {
    this.eventHandlers.delete(eventType);
  }

  get subscribed() { return this._subscribed; }

  private _dispatchEvent(env: Envelope): void {
    // Dispatch to specific handlers
    const specific = this.eventHandlers.get(env.type);
    if (specific) {
      for (const handler of specific) {
        try { handler(env); } catch { /* swallow handler errors */ }
      }
    }
    // Dispatch to wildcard handlers
    const wildcard = this.eventHandlers.get("*");
    if (wildcard) {
      for (const handler of wildcard) {
        try { handler(env); } catch { /* swallow handler errors */ }
      }
    }
  }
}
