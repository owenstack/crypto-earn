# CEX-ZIG — Hyperliquid Trading Engine Migration PRD,
## Context

### Project description

`cex-zig` is a production-grade, low-latency crypto trading engine built with a Zig core and a TypeScript control plane. It was originally built for Polymarket (a prediction market CLOB) and proved the architecture. This migration replaces the Polymarket integration layer with Hyperliquid (HL) — a fully on-chain L1 CLOB DEX supporting perpetual futures at 100,000+ orders/second — while preserving all infrastructure: SQLite WAL persistence, UNIX socket IPC, Telegram/dashboard control plane, Docker Compose deployment, and the strategy signal pipeline.

The rewrite enables two live trading strategies — Pure Market Making (LP) and CEX-to-DEX Statistical Arbitrage — to be validated first in dry-run mode on the Hyperliquid testnet, then promoted to live trading on AWS EC2 us-east-1 to minimise network latency to both Hyperliquid and Binance Futures servers.

### Business objectives

- Replace Polymarket-specific auth, order signing, and market data with Hyperliquid equivalents.
- Implement both trading strategies with full risk gate and portfolio tracking adapted for perpetual futures margin semantics.
- Provide an accurate paper-trading (dry-run) layer on the Hyperliquid testnet so strategy viability can be confirmed before any real capital is deployed.
- Deploy on AWS EC2 us-east-1 to exploit co-location proximity to Hyperliquid and Binance infrastructure.

### Technical constraints

- Language: Zig 0.15.2 (engine), Bun/TypeScript (control plane)
- Database: SQLite 3.35+ with WAL mode
- Deployment: Docker Compose on AWS EC2 (us-east-1)
- Signing: EIP-712 + secp256k1 (already implemented in `crypto.zig`)
- New primitive: MessagePack (msgpack) binary serialisation for Hyperliquid order payloads
- Hyperliquid testnet endpoint: `api.hyperliquid-testnet.xyz`
- Hyperliquid mainnet endpoint: `api.hyperliquid.xyz`
- Binance Futures WebSocket: `wss://fstream.binance.com`

---

## Product overview

The migrated `cex-zig` is a self-hosted, low-latency perpetual futures trading engine that connects to Hyperliquid as its primary exchange and Binance Futures as its secondary price feed. It operates autonomously under configurable risk limits, controlled entirely through a Telegram bot and a read-only web dashboard. It supports a testnet dry-run mode for paper trading and a live mode for real capital deployment. All order placement, risk checking, fill detection, portfolio tracking, and strategy evaluation run in the Zig engine process; the TypeScript control plane handles only human-facing observability and control.

---

## Goals

### Business goals

- **BG-01** Achieve profitable paper-trading P&L on Hyperliquid testnet across both strategies before any live capital is risked.
- **BG-02** Demonstrate sub-50ms order submission latency from AWS EC2 us-east-1 to Hyperliquid.
- **BG-03** Reduce per-trade cost to near-zero by capturing the HL maker rebate (0.0 bps or negative) on the LP strategy.
- **BG-04** Exploit the Binance → Hyperliquid price-propagation lag window (estimated 10–50 ms from us-east-1) for the arb strategy.
- **BG-05** Maintain the existing Telegram + dashboard operational model with zero regression in observability.

### User goals

- **UG-01** As the operator, I want to run both strategies simultaneously in dry-run mode on the testnet and receive accurate simulated P&L so I can decide when each strategy is viable.
- **UG-02** As the operator, I want to promote from dry-run to live with a single config flag, not a code change.
- **UG-03** As the operator, I want the Telegram bot to notify me of fills, rejections, engine state changes, and arb opportunities in real time.
- **UG-04** As the operator, I want the risk gate to enforce margin-aware position limits so a single bad trade cannot blow the account.
- **UG-05** As the operator, I want latency telemetry (order submission, fill detection, arb trigger-to-fire) logged and queryable from the dashboard and telegram control plane.

### Non-goals

- Spot trading on Hyperliquid (perpetuals only in this scope).
- Multi-account or multi-wallet support.
- Web-based order entry (Telegram bot is the sole control surface).
- On-chain contract deployment or smart contract interaction beyond what the HL SDK requires.
- Building a backtesting engine against historical data (testnet paper trading is the validation method).
- Support for exchanges other than Hyperliquid (primary) and Binance Futures (price feed only).

---

## User personas

### Persona 1 — Solo operator / system owner

| Attribute | Detail |
|-----------|--------|
| Role | Engine owner, sole user |
| Technical level | High — full-stack developer, comfortable reading Zig and TypeScript source |
| Access level | Full: Telegram bot admin, SSH to EC2, direct SQLite access |
| Primary need | Confidence that both strategies are profitable before live deployment |
| Key frustration | Unexpected naked positions, silent failures, stale balance reads |
| Session pattern | Sets strategy params via Telegram, monitors dashboard, reviews logs after fills |

### Persona 2 — Auditor / future team member

| Attribute | Detail |
|-----------|--------|
| Role | Observer, read-only |
| Technical level | Medium |
| Access level | Read-only web dashboard only (Bearer token required) |
| Primary need | Understand current portfolio state, P&L, open orders |
| Key frustration | Dashboard showing stale or missing data |

---

## Functional requirements

### P0 — Must have for testnet dry-run launch

| ID | Requirement |
|----|-------------|
| FR-01 | MsgPack encoder for Zig that serialises the HL Order struct byte-perfectly for EIP-712 hashing |
| FR-02 | Hyperliquid API Wallet authentication: env-loaded private key, derived address, no external bootstrap |
| FR-03 | Asset index fetch on startup: POST `/info` `{"type":"meta"}` → in-memory HashMap `"BTC"→0` |
| FR-04 | Single-endpoint order placement: POST `https://api.hyperliquid.xyz/exchange` with signed action payload |
| FR-05 | Order cancellation via the same `/exchange` endpoint with `"cancel"` action type |
| FR-06 | l2Book WebSocket connection to `wss://api.hyperliquid.xyz/ws` with snapshot + delta application |
| FR-07 | In-memory sorted BTreeMap-equivalent for bid/ask levels, updated on each delta message |
| FR-08 | Mid-price calculation maintained continuously from live orderbook state |
| FR-09 | Risk gate rewrite: notional exposure in USD = position_size × mark_price, not USDC collateral cost |
| FR-10 | Risk gate: max margin utilisation check against `clearinghouseState.marginSummary.accountValue` |
| FR-11 | Portfolio tracker: query `clearinghouseState` for equity, open positions, unrealised PnL |
| FR-12 | Fill detection: WebSocket user channel subscription on HL for real-time order events |
| FR-13 | Dry-run mode on testnet: all order actions intercepted, logged to `dry_run_orders`, no real API calls |
| FR-14 | Testnet/mainnet toggle via `HL_NETWORK=testnet|mainnet` environment variable |
| FR-15 | Inventory skew check: after a long fill, suppress further bids and lower the ask to exit the position |
| FR-16 | LP strategy: tighten spread to `lp_min_spread=0.0005` (5 bps) from the previous 6% |
| FR-17 | Delete all Polymarket-specific source files from the Zig engine |
| FR-18 | Database schema migration adding HL-specific fields (asset index, mark price, funding rate) |
| FR-19 | IPC types updated to reflect HL semantics (remove Polymarket/Kalshi/Gamma/CTF references) |
| FR-20 | Testnet funding: operator can request testnet USDC via the HL faucet; engine detects testnet balance |

### P1 — Must have before live launch

| ID | Requirement |
|----|-------------|
| FR-21 | Binance Futures WebSocket: `wss://fstream.binance.com/ws/<symbol>@bookTicker` for real-time BBO |
| FR-22 | Arb strategy: compute `binance_mid − hl_mid` delta continuously with microsecond timestamps |
| FR-23 | Arb trigger: if `abs(delta) >= arb_threshold_bps` and delta is stable for `arb_confirm_ms`, fire a taker order on HL |
| FR-24 | Arb strategy: configurable `arb_threshold_bps` (default 10), `arb_confirm_ms` (default 5), `arb_max_size_usd` |
| FR-25 | Latency telemetry: log `binance_event_ts`, `hl_event_ts`, `order_submit_ts`, `fill_ts` per arb trade |
| FR-26 | Circuit breaker for arb: halt arb submissions if last 5 arb orders were all losses |
| FR-27 | Funding rate fetch: poll HL `/info` `{"type":"fundingRate"}` every 5 minutes; pause LP if rate is adverse |
| FR-28 | Mark price tracking: store latest mark price per asset in SQLite for accurate unrealised PnL |
| FR-29 | Reconciliation on startup: compare local open orders with HL order status and correct mismatches |
| FR-30 | Stale order scanner: cancel orders older than `max_order_age_minutes` (default 10 for perps) |
| FR-31 | Dashboard: rename all Polymarket-specific labels to HL equivalents (equity, margin, funding, etc.) |
| FR-32 | Telegram: new `/funding` command showing current funding rate and next payment time |
| FR-33 | Telegram: `/arb` command showing last 10 arb events with delta, size, and realised PnL |
| FR-34 | Paper trading P&L report: `/drystatus` enhanced with per-strategy breakdown and fill rate by asset |

### P2 — Nice to have

| ID | Requirement |
|----|-------------|
| FR-35 | Multi-asset support: subscribe to l2Book and arb feed for up to 5 assets simultaneously |
| FR-36 | Funding rate arbitrage detection: alert operator when funding rate exceeds `funding_alert_bps` |
| FR-37 | Order book depth visualisation in the web dashboard (top 5 bid/ask levels per asset) |
| FR-38 | AWS CloudWatch log forwarding for engine stdout |
| FR-39 | Automated EC2 instance health check with auto-restart on engine crash |
| FR-40 | Terraform module for EC2 provisioning in us-east-1 (instance type, security group, EBS volume) |

---

## User experience flow

### Entry point — Initial setup

The operator clones the repository onto an AWS EC2 instance in us-east-1. They copy `.env.example` to `.env`, set `HL_NETWORK=testnet`, populate `HL_API_PRIVATE_KEY` (their API Wallet private key), and run `docker compose up -d --build`. On startup the engine fetches the asset index from Hyperliquid, connects the l2Book WebSocket, authenticates with the testnet, and waits. The operator uses `/drystatus` in Telegram to confirm the engine sees live orderbook data before enabling any strategy.

### Core experience — Dry-run paper trading

The operator enables both strategies via Telegram: `/strategy enable market_making` and `/strategy enable cex_dex_arb` or as an env variable change. The engine begins generating signals against the live testnet orderbook. All order actions are written to `dry_run_orders` and simulated fills are settled against live bid/ask prices every 30 seconds. The operator watches `/drystatus` daily to review paper P&L, fill rate, and win rate. The dashboard shows a "TESTNET DRY-RUN" badge in red so the operator is never confused about which environment is active.

### Promotion to live — Mainnet switch

Once paper trading shows consistent positive expectancy over a minimum of 7 days, the operator changes `HL_NETWORK=mainnet`, sets `DRY_RUN=0`, and restarts the engine. The startup sequence validates the mainnet API wallet balance, runs reconciliation, and opens the order placement gate. The Telegram bot sends a `🚀 ENGINE LIVE — mainnet` notification.

### Ongoing operation

The operator monitors fills and funding rate events via Telegram push notifications. They use `/config set arb_threshold_bps 8` to tune the arb trigger dynamically without a restart. The dashboard provides a read-only view of equity, open positions, active orders, and system logs. The `/funding` command lets the operator decide whether to pause LP during adverse funding periods.

---

## Technical considerations

### Architecture — what changes and what stays

| Component | Action | Reason |
|-----------|--------|--------|
| `polymarket_auth.zig` | **Delete** | Replaced by `hl_auth.zig` |
| `gamma_api.zig` | **Delete** | No equivalent concept on HL |
| `kalshi_ws.zig` | **Delete** | Replaced by Binance Futures WS |
| `news_sources.zig` | **Delete** | No news-repricing strategy on HL |
| `market_scanner.zig` | **Delete** | Replaced by startup asset-index fetch |
| `probability_provider.zig` | **Delete** | No probability model needed |
| `clob_orderbook.zig` | **Delete** | Replaced by `hl_orderbook.zig` |
| `websocket.zig` | **Rewrite** | Points to HL l2Book endpoint |
| `order_manager.zig` | **Rewrite** | Single `/exchange` endpoint, asset index, msgpack signing |
| `fill_poller.zig` | **Rewrite** | HL user WebSocket channel, different event schema |
| `risk_gate.zig` | **Rewrite** | Margin model: notional exposure / account equity |
| `portfolio_tracker.zig` | **Rewrite** | `clearinghouseState` API, margin summary |
| `strategy_engine.zig` | **Extend** | Add `cex_dex_arb` strategy, tighten LP params |
| `crypto.zig` | **Keep** | EIP-712 + secp256k1 reused directly |
| `db.zig` | **Extend** | New migrations for HL fields |
| `ipc.zig` / `ipc_types.zig` | **Extend** | New IPC message types, remove old ones |
| `logger.zig` | **Keep** | Unchanged |
| `crash_trace.zig` | **Keep** | Unchanged |
| `http_client.zig` | **Keep** | Unchanged |
| TypeScript control plane | **Extend** | New labels, new Telegram commands, dashboard badge |

### New source files required

| File | Purpose |
|------|---------|
| `zig/src/msgpack.zig` | Minimal MsgPack encoder for the HL Order struct |
| `zig/src/hl_auth.zig` | API Wallet key loading, EIP-712 domain for HL (chainId 1337), signature assembly |
| `zig/src/hl_order_manager.zig` | POST `/exchange` order placement and cancellation |
| `zig/src/hl_orderbook.zig` | l2Book WebSocket handler: snapshot ingestion, delta application, mid-price |
| `zig/src/hl_market_meta.zig` | Asset index fetch and in-memory lookup |
| `zig/src/hl_fill_poller.zig` | HL user WebSocket for real-time fills and order events |
| `zig/src/hl_portfolio_tracker.zig` | `clearinghouseState` polling, equity and position tracking |
| `zig/src/binance_ws.zig` | Binance Futures `bookTicker` WebSocket, BBO feed |
| `zig/src/cex_dex_arb.zig` | Arb strategy: delta computation, trigger, taker order dispatch |

### MsgPack encoding

Hyperliquid requires the action JSON to be MessagePack-encoded before keccak256 hashing and EIP-712 signing. The encoder must produce bytes byte-identical to the reference Python `msgpack` library output for the Order struct. The field ordering in the packed map is fixed and must match the HL SDK exactly. This must be validated against the HL testnet before any other module depends on it.

### Signing flow (HL vs Polymarket)

```
Polymarket: EIP-712(CTFOrder struct) → secp256k1 sign → hex sig
Hyperliquid: keccak256(msgpack(action_json)) → EIP-712 wrap (chainId 1337) → secp256k1 sign → {r,s,v} JSON
```

### Risk gate — margin model

The current risk gate measures exposure as `size_shares × price` in USDC collateral terms. On Hyperliquid with leverage, the correct model is:

```
notional_usd = position_size × mark_price
margin_used  = notional_usd / leverage
max_notional = account_equity × max_leverage_pct
```

The gate must reject orders that would push `current_notional + new_notional > account_equity × max_leverage_pct`. The `max_leverage_pct` is configurable (default: 5× effective leverage = 20% equity as margin).

### Inventory skew (LP strategy)

After a long fill, the engine must:
1. Immediately cancel any remaining bid orders on that asset.
2. Shift the ask price down toward the mid to accelerate position exit.
3. Resume symmetric quoting only after the inventory returns below `inventory_exit_threshold_shares`.

This prevents the engine from doubling a long position during adverse price moves.

### CEX-DEX arb timing

From AWS EC2 us-east-1:
- Binance Futures WebSocket RTT: ~4–8 ms
- Hyperliquid API RTT: ~10–20 ms (HL is also us-east-1 infrastructure)
- Expected usable lag window: 15–40 ms

The arb strategy must track `binance_update_ns` and `hl_submit_ns` per trade to measure the actual captured window. If the median captured window shrinks below `arb_min_window_ms=5`, the strategy should self-disable and alert the operator.

### Dry-run vs live parity

The dry-run layer must simulate:
- Order placement latency (sampled from a configurable distribution, default: `uniform(8ms, 25ms)`)
- Slippage: fills simulated at the best ask (buys) or best bid (sells) from the live l2Book snapshot at fill time
- Fees: taker 0.035% (3.5 bps), maker 0.0% (rebate not modelled in dry-run to be conservative)
- Funding rate charges: accrued every 8 hours against open simulated positions

### AWS EC2 deployment

- Region: `us-east-1` (Virginia)
- Recommended instance: `c6i.xlarge` (4 vCPU, 8 GB RAM) — compute-optimised for Zig engine throughput
- Storage: `gp3` EBS 20 GB for SQLite WAL; enable EBS optimisation
- Networking: placement in a subnet with direct internet egress; no NAT gateway (reduces latency)
- Security group: inbound SSH only; outbound all (Hyperliquid, Binance, Telegram APIs)
- IAM role: CloudWatch Logs write permission only
- Elastic IP: assign a static IP to avoid reconnect issues after instance stop/start

### Data storage

New SQLite migrations required:

| Table / column | Change |
|----------------|--------|
| `markets` | Remove `clob_token_ids`, `condition_id`, `neg_risk`; add `asset_index INTEGER`, `base_asset TEXT`, `max_leverage INTEGER` |
| `orders` | Remove `lp_pair_order_id` (retained as `pair_order_id` generic); add `asset_index INTEGER`, `reduce_only BOOLEAN` |
| `positions` | Add `mark_price REAL`, `funding_accrued REAL`, `leverage INTEGER` |
| `funding_snapshots` (new) | `asset TEXT`, `rate REAL`, `next_payment_ts INTEGER`, `snapshot_at INTEGER` |
| `arb_events` (new) | `asset TEXT`, `binance_mid REAL`, `hl_mid REAL`, `delta_bps REAL`, `order_id TEXT`, `realised_pnl REAL`, `submit_ns INTEGER`, `fill_ns INTEGER`, `created_at INTEGER` |
| `dry_run_orders` | Add `funding_charge REAL`, `simulated_slippage REAL` |

### Scalability and performance

- The l2Book delta handler must complete in under 50 µs per message to avoid backpressure on the WebSocket read loop.
- The arb delta computation runs in the same thread as the Binance WS reader; it must not block on DB writes.
- DB writes for telemetry (arb events, funding snapshots) use a dedicated write thread via a bounded channel, not inline on the hot path.
- SQLite WAL autocheckpoint remains at 1000 pages; retention runs every 15 minutes as before.

---

## Success metrics

### User-centric metrics

| Metric | Target |
|--------|--------|
| Paper trading fill rate (LP) | ≥ 40% of quotes filled per session |
| Paper trading win rate (arb) | ≥ 55% of arb trades profitable |
| Paper trading net P&L (7-day) | Positive on both strategies |
| Telegram notification latency | Fill event delivered within 2 s of detection |
| `/drystatus` accuracy | Simulated P&L within 5% of what live would produce |

### Business metrics

| Metric | Target |
|--------|--------|
| Live maker rebate captured | ≥ 80% of LP orders placed as maker |
| Arb captured lag window | Median > 10 ms from Binance event to HL order submit |
| Account equity drawdown (live) | < 15% peak-to-trough in any 24-hour period |
| Engine uptime | ≥ 99.5% (< 4 h downtime/month) |

### Technical metrics

| Metric | Target |
|--------|--------|
| Order submission latency (p99) | < 30 ms from signal to HL API acknowledgement |
| Fill detection latency (p99) | < 500 ms from HL event to local DB update |
| MsgPack encode time | < 5 µs per order |
| l2Book delta application time | < 50 µs per message |
| Engine memory usage | < 256 MB RSS steady-state |
| SQLite DB size after 30 days | < 500 MB |

---

## Milestones and sequencing

**Total estimated effort:** 6–8 weeks solo development  
**Team size:** 1 engineer (full-stack, Zig + TypeScript)  
**Environment:** AWS EC2 us-east-1, Hyperliquid testnet first, mainnet after paper trading validation

### Milestone 1 — Signing foundation (Week 1)

Deliver a working MsgPack encoder and Hyperliquid order signer validated against the testnet. No order placement yet, just provably correct bytes. Gate: a manually constructed order is accepted by the testnet `/exchange` endpoint without signature error.

### Milestone 2 — Market data and order execution (Week 2)

Deliver l2Book WebSocket handler with live mid-price, asset index fetch, and single order placement/cancellation through the new `hl_order_manager.zig`. Gate: a market order on the testnet fills and appears in the local DB.

### Milestone 3 — Portfolio and fill tracking (Week 3)

Deliver `hl_portfolio_tracker.zig` querying `clearinghouseState`, `hl_fill_poller.zig` detecting fills via HL user WebSocket, and the rewritten risk gate with margin semantics. Gate: `/balance` and `/portfolio` in Telegram show correct equity and open positions.

### Milestone 4 — LP strategy dry-run (Week 4)

Deliver the tightened LP strategy with inventory skew check, running in dry-run mode on testnet for a full 7-day paper trading period. Gate: `/drystatus` shows positive net P&L and ≥ 40% fill rate over 7 days.

### Milestone 5 — Arb strategy and Binance feed (Week 5)

Deliver `binance_ws.zig`, `cex_dex_arb.zig`, and latency telemetry. Run arb in dry-run on testnet for 7 days. Gate: `/arb` shows ≥ 55% win rate and positive P&L over 7 days.

### Milestone 6 — Dashboard and Telegram updates (Week 6)

Deliver all TypeScript control plane changes: new Telegram commands (`/funding`, `/arb`), updated dashboard labels, testnet/mainnet badge, per-strategy dry-run P&L breakdown. Gate: all Telegram commands return correct data with no Polymarket references visible.

### Milestone 7 — Mainnet live launch (Week 7–8)

Deploy to AWS EC2 us-east-1 with `HL_NETWORK=mainnet`, `DRY_RUN=0`. Run both strategies with minimal size for 48 hours. Gate: first real fill detected, equity tracked correctly, no naked positions.

---

## User stories

### Authentication and configuration

- [ ] **PP-ITEM-1.1**
  - **ID:** US-001
  - **Title:** API Wallet key loading
  - **Description:** As the operator, I want the engine to load the HL API Wallet private key from the `HL_API_PRIVATE_KEY` environment variable, derive the Ethereum address, and log the address on startup so I can confirm the correct wallet is active.
  - **Acceptance criteria:**
    - AC-001-1: Engine starts successfully when `HL_API_PRIVATE_KEY` is a valid 64-char hex string.
    - AC-001-2: Derived Ethereum address is logged in EIP-55 checksum format on startup.
    - AC-001-3: Engine logs a clear error and refuses to start if `HL_API_PRIVATE_KEY` is missing or malformed.
    - AC-001-4: The private key is not logged or included in any telemetry output.

- [ ] **PP-ITEM-1.2**
  - **ID:** US-002
  - **Title:** Testnet/mainnet toggle
  - **Description:** As the operator, I want to switch between testnet and mainnet with a single environment variable so I can test safely before using real capital.
  - **Acceptance criteria:**
    - AC-002-1: `HL_NETWORK=testnet` routes all API calls to `api.hyperliquid-testnet.xyz`.
    - AC-002-2: `HL_NETWORK=mainnet` routes all API calls to `api.hyperliquid.xyz`.
    - AC-002-3: The Telegram bot and dashboard display a `TESTNET` or `MAINNET` badge in every status message.
    - AC-002-4: `HL_NETWORK` defaults to `testnet` if unset (fail-safe).
    - AC-002-5: Engine refuses to start if `HL_NETWORK` is set to an unrecognised value.

### MsgPack and signing

- [ ] **PP-ITEM-2.1**
  - **ID:** US-003
  - **Title:** MsgPack order encoding
  - **Description:** As the engine, I want to encode a Hyperliquid Order struct into MessagePack bytes that are byte-identical to the reference implementation so the resulting EIP-712 hash is accepted by the HL validator.
  - **Acceptance criteria:**
    - AC-003-1: `msgpack.zig` encodes the full Order struct fields in the canonical HL field order.
    - AC-003-2: Encoding produces output byte-identical to the Python `msgpack` reference for 10 known test vectors.
    - AC-003-3: A manually submitted signed order using this encoder is accepted by the HL testnet `/exchange` endpoint without a `signature invalid` error.
    - AC-003-4: Encoding completes in under 5 µs on the target EC2 instance.

- [ ] **PP-ITEM-2.2**
  - **ID:** US-004
  - **Title:** HL EIP-712 signature construction
  - **Description:** As the engine, I want to produce a valid EIP-712 signature for every order using the HL domain (chainId 1337) so orders are accepted by the exchange.
  - **Acceptance criteria:**
    - AC-004-1: Domain separator uses `chainId=1337` for mainnet and `chainId=421614` for testnet (or the published HL testnet chain ID).
    - AC-004-2: Signature `{r, s, v}` is included as a JSON object in the order payload.
    - AC-004-3: A signed limit order on the testnet fills when the price crosses.
    - AC-004-4: Signing is performed using the API Wallet private key, not the main wallet key.

### Market data

- [ ] **PP-ITEM-3.1**
  - **ID:** US-005
  - **Title:** Asset index fetch on startup
  - **Description:** As the engine, I want to fetch the asset index map from Hyperliquid on startup so I can reference assets by integer index in all order payloads.
  - **Acceptance criteria:**
    - AC-005-1: Engine calls POST `/info` with `{"type":"meta"}` on startup before accepting any orders.
    - AC-005-2: The returned `universe` array is parsed into an in-memory HashMap of `"SYMBOL" → asset_index`.
    - AC-005-3: Engine logs the number of assets loaded (e.g., `"asset index loaded: 142 assets"`).
    - AC-005-4: If the fetch fails, engine retries up to 3 times with 2s backoff before halting.
    - AC-005-5: The asset index is refreshed every 24 hours without requiring a restart.

- [ ] **PP-ITEM-3.2**
  - **ID:** US-006
  - **Title:** l2Book WebSocket connection and snapshot ingestion
  - **Description:** As the engine, I want to connect to the Hyperliquid l2Book WebSocket and ingest the full initial snapshot so I have an accurate orderbook on which to base quotes.
  - **Acceptance criteria:**
    - AC-006-1: Engine subscribes to `{"method":"subscribe","subscription":{"type":"l2Book","coin":"BTC"}}` on connection.
    - AC-006-2: The initial snapshot message populates the in-memory bid and ask level arrays.
    - AC-006-3: Mid-price is computed as `(best_bid + best_ask) / 2` after each snapshot and delta.
    - AC-006-4: Delta messages are applied incrementally: a level with `sz=0` is removed; a new price level is inserted in sorted order.
    - AC-006-5: Delta application completes in under 50 µs per message.
    - AC-006-6: On WebSocket disconnect, engine reconnects with exponential backoff (1s → 30s max) and re-subscribes.

- [ ] **PP-ITEM-3.3**
  - **ID:** US-007
  - **Title:** Binance Futures BBO WebSocket
  - **Description:** As the engine, I want a real-time best-bid/offer feed from Binance Futures so the arb strategy can detect price divergence between Binance and Hyperliquid.
  - **Acceptance criteria:**
    - AC-007-1: Engine connects to `wss://fstream.binance.com/ws/<symbol>@bookTicker` for each configured asset.
    - AC-007-2: Each `bookTicker` message updates the in-memory Binance mid-price with a nanosecond timestamp.
    - AC-007-3: On disconnect, engine reconnects within 2 s and logs a warning.
    - AC-007-4: If Binance WS is unavailable for more than 30 s, the arb strategy is automatically paused.
    - AC-007-5: The Binance feed adds no observable latency to the HL order submission path.

### Order management

- [ ] **PP-ITEM-4.1**
  - **ID:** US-008
  - **Title:** Limit order placement on Hyperliquid
  - **Description:** As the engine, I want to place a signed limit order on Hyperliquid through the `/exchange` endpoint so quotes appear on the orderbook.
  - **Acceptance criteria:**
    - AC-008-1: Order payload includes `asset_index`, `is_buy`, `limit_px`, `sz`, `reduce_only`, `order_type.limit.tif` fields.
    - AC-008-2: `nonce` is set to `Date.now()` in milliseconds.
    - AC-008-3: Successful response contains an order ID that is persisted to the local `orders` table with status `placed`.
    - AC-008-4: On `429 Too Many Requests`, the engine retries with exponential backoff (1s base, 7 retries, 60s cap).
    - AC-008-5: Order submission latency (signal-to-API-ack) is logged per order for p99 tracking.

- [ ] **PP-ITEM-4.2**
  - **ID:** US-009
  - **Title:** Order cancellation on Hyperliquid
  - **Description:** As the engine, I want to cancel a specific order by ID through the HL `/exchange` endpoint so resting quotes can be pulled when the edge collapses.
  - **Acceptance criteria:**
    - AC-009-1: Cancel payload uses `"cancel"` action type with `coin` string and `oid` integer.
    - AC-009-2: Successful cancel updates the local DB order status to `cancelled`.
    - AC-009-3: If the order is already filled, the local DB is updated to `filled` without error.
    - AC-009-4: Cancel-all (`/halt`) cancels all open HL orders within 5 seconds.

### Fill detection and portfolio

- [ ] **PP-ITEM-5.1**
  - **ID:** US-010
  - **Title:** Real-time fill detection via HL user WebSocket
  - **Description:** As the engine, I want to detect fills in real time via the HL user WebSocket channel so portfolio and P&L are updated within 500 ms of a fill occurring.
  - **Acceptance criteria:**
    - AC-010-1: Engine subscribes to the HL user WebSocket channel on startup with the API Wallet credentials.
    - AC-010-2: A `fill` event updates the local `orders` table status and creates a `fills` row within 500 ms.
    - AC-010-3: A Telegram `✅ Order Filled` notification is sent within 2 s of the fill event.
    - AC-010-4: Partially filled orders are updated to `partially_filled` status with correct `filled_size`.
    - AC-010-5: Fill detection falls back to REST polling every 5 s if the WebSocket is unavailable.

- [ ] **PP-ITEM-5.2**
  - **ID:** US-011
  - **Title:** Portfolio equity tracking from clearinghouseState
  - **Description:** As the operator, I want the engine to track my account equity and open positions from the Hyperliquid `clearinghouseState` API so risk limits and the dashboard reflect the real margin state.
  - **Acceptance criteria:**
    - AC-011-1: Engine polls `{"type":"clearinghouseState","user":"<MAIN_WALLET>"}` every 60 seconds.
    - AC-011-2: `marginSummary.accountValue` is written to `balance_snapshots` and used by the risk gate.
    - AC-011-3: Open perpetual positions (asset, side, size, entry price, unrealised PnL) are stored in the `positions` table.
    - AC-011-4: `/balance` in Telegram shows equity, total margin used, and unrealised PnL.
    - AC-011-5: If the equity fetch fails 3 consecutive times, engine pauses strategy evaluation and alerts the operator.

### Risk gate

- [ ] **PP-ITEM-6.1**
  - **ID:** US-012
  - **Title:** Margin-aware position size limit
  - **Description:** As the engine, I want the risk gate to reject orders that would push my notional exposure beyond a configurable multiple of account equity so a single large position cannot blow the account.
  - **Acceptance criteria:**
    - AC-012-1: Risk gate computes `new_notional = order_size × limit_price` and checks `current_notional + new_notional ≤ account_equity × max_leverage_pct`.
    - AC-012-2: `max_leverage_pct` defaults to 5.0 (5× effective leverage) and is configurable via `/config set`.
    - AC-012-3: Rejected orders are logged to `risk_events` with `check_name="margin_leverage_limit"`.
    - AC-012-4: A Telegram `🛡️ Risk Rejection` event is pushed for every rejection.
    - AC-012-5: The risk gate uses the most recent `accountValue` snapshot; if older than `balance_snapshot_max_age_seconds`, it falls back to the absolute fallback limits.

- [ ] **PP-ITEM-6.2**
  - **ID:** US-013
  - **Title:** Inventory skew enforcement after fill
  - **Description:** As the engine, I want the LP strategy to suppress further same-side bids after a long fill and aggressively lower the ask so the position is exited quickly without accumulating directional risk.
  - **Acceptance criteria:**
    - AC-013-1: After a buy fill of size ≥ `inventory_skew_threshold_shares` (default 0.01 BTC), all remaining bid orders on the asset are cancelled within 1 s.
    - AC-013-2: The next sell quote is placed at `mid_price − skew_offset_bps` (default 2 bps) instead of the normal ask quote.
    - AC-013-3: Normal symmetric quoting resumes when `net_long_inventory < inventory_exit_threshold_shares` (default 0.005 BTC).
    - AC-013-4: Inventory state persists across engine restarts by reading `positions` table on startup.

### Strategies

- [ ] **PP-ITEM-7.1**
  - **ID:** US-014
  - **Title:** LP strategy with tight spread quoting
  - **Description:** As the engine, I want the LP strategy to quote a 5 bps spread around the HL mid-price for configured assets so I capture the maker rebate thousands of times per day.
  - **Acceptance criteria:**
    - AC-014-1: `lp_min_spread` defaults to `0.0005` (5 bps).
    - AC-014-2: Bid is placed at `mid × (1 − spread/2)` and ask at `mid × (1 + spread/2)`, rounded to HL tick size.
    - AC-014-3: Quotes are refreshed whenever the mid-price moves by more than `lp_requote_threshold_bps` (default 2 bps).
    - AC-014-4: LP strategy does not place orders if the HL taker fee would exceed the expected rebate (checked against the current order book depth).
    - AC-014-5: Funding rate fetch pauses LP if the hourly funding rate magnitude exceeds `lp_max_funding_bps` (default 5 bps).

- [ ] **PP-ITEM-7.2**
  - **ID:** US-015
  - **Title:** CEX-DEX arb strategy delta computation
  - **Description:** As the engine, I want the arb strategy to compute the Binance–Hyperliquid mid-price delta continuously so I can fire taker orders in the direction of price convergence within the lag window.
  - **Acceptance criteria:**
    - AC-015-1: Delta is computed as `binance_mid − hl_mid` with both values timestamped to nanosecond resolution.
    - AC-015-2: A buy taker order is fired on HL when `delta ≥ arb_threshold_bps × hl_mid / 10000` and the delta has been stable for `arb_confirm_ms`.
    - AC-015-3: A sell taker order is fired on HL when `delta ≤ −arb_threshold_bps × hl_mid / 10000`.
    - AC-015-4: Order size is capped at `arb_max_size_usd` (default $500) regardless of computed signal strength.
    - AC-015-5: A circuit breaker disables arb for 30 minutes after 5 consecutive losing trades.
    - AC-015-6: Each arb event is written to the `arb_events` table with full latency breakdown.

### Dry-run and paper trading

- [ ] **PP-ITEM-8.1**
  - **ID:** US-016
  - **Title:** Dry-run mode on testnet
  - **Description:** As the operator, I want dry-run mode to simulate all order placements against the live testnet orderbook without submitting real API calls so I can validate strategy viability safely.
  - **Acceptance criteria:**
    - AC-016-1: When `DRY_RUN=1`, no POST requests are made to `/exchange`.
    - AC-016-2: Simulated orders are written to `dry_run_orders` with `status=open`.
    - AC-016-3: Simulated fills are settled every 30 seconds against the live testnet l2Book: buy fills at best ask, sell fills at best bid.
    - AC-016-4: Simulated latency of `uniform(8ms, 25ms)` is applied before checking fill eligibility.
    - AC-016-5: Taker fee of 3.5 bps is deducted from each simulated fill; maker fills are at 0.0 bps.
    - AC-016-6: Funding charges are accrued against open dry-run positions at each 8-hour funding interval.
    - AC-016-7: The simulated USDC balance starts at `DRY_RUN_INITIAL_BALANCE` and is updated after each settled fill.

- [ ] **PP-ITEM-8.2**
  - **ID:** US-017
  - **Title:** Dry-run P&L report via Telegram
  - **Description:** As the operator, I want `/drystatus` to show an accurate per-strategy paper trading summary so I can decide when each strategy is ready for live deployment.
  - **Acceptance criteria:**
    - AC-017-1: `/drystatus` shows: total signals, filled trades, fill rate %, win rate %, net P&L, max drawdown, avg hold time, diagnosis verdict per strategy.
    - AC-017-2: Per-strategy breakdown separates LP results from arb results.
    - AC-017-3: Diagnosis verdict is one of: `no_data`, `no_fills_detected`, `paper_loss`, `fill_rate_too_low`, `paper_viable`.
    - AC-017-4: Report covers the last 7 days by default; operator can request `today`, `7d`, `30d`, `all`.
    - AC-017-5: A `TESTNET` watermark appears at the top of every `/drystatus` output.

### Telegram control plane

- [ ] **PP-ITEM-9.1**
  - **ID:** US-018
  - **Title:** Funding rate command
  - **Description:** As the operator, I want a `/funding` command in Telegram that shows the current HL funding rate per asset and the next payment time so I can make informed decisions about pausing LP.
  - **Acceptance criteria:**
    - AC-018-1: `/funding` shows: asset name, current hourly funding rate (bps), annualised rate (%), next payment timestamp.
    - AC-018-2: Funding rate data is fetched from the HL `/info` endpoint no older than 5 minutes.
    - AC-018-3: Assets with adverse funding (above `lp_max_funding_bps`) are highlighted with a ⚠️ indicator.
    - AC-018-4: Command is accessible only from allowed Telegram chat IDs.

- [ ] **PP-ITEM-9.2**
  - **ID:** US-019
  - **Title:** Arb event history command
  - **Description:** As the operator, I want a `/arb` command in Telegram showing the last 10 arb events so I can review recent strategy execution.
  - **Acceptance criteria:**
    - AC-019-1: `/arb` shows for each event: asset, Binance mid, HL mid, delta (bps), order size (USD), realised P&L, submit latency (ms).
    - AC-019-2: Results are sorted newest first.
    - AC-019-3: If no arb events exist, bot replies with `"No arb events recorded yet."`.
    - AC-019-4: Command queries the `arb_events` table directly from the SQLite DB.

### Dashboard and observability

- [ ] **PP-ITEM-10.1**
  - **ID:** US-020
  - **Title:** Dashboard updated for Hyperliquid semantics
  - **Description:** As the operator, I want the web dashboard to display HL-specific metrics (equity, margin used, funding accrued, mark price) instead of Polymarket metrics so the dashboard is useful for perp trading.
  - **Acceptance criteria:**
    - AC-020-1: KPI cards show: Account Equity (USDC), Margin Used (%), Daily P&L (USD), Engine Status.
    - AC-020-2: Positions table shows: asset, side, size, entry price, mark price, unrealised PnL, funding accrued.
    - AC-020-3: Market Tracker shows: asset, Binance mid, HL mid, spread (bps), last l2Book update timestamp.
    - AC-020-4: A `TESTNET` badge (orange) or `MAINNET` badge (green) is visible in the header at all times.
    - AC-020-5: No Polymarket, Gamma, Kalshi, or CTF references appear anywhere in the dashboard.

### Deployment and infrastructure

- [ ] **PP-ITEM-11.1**
  - **ID:** US-021
  - **Title:** AWS EC2 us-east-1 deployment
  - **Description:** As the operator, I want the engine deployed on an AWS EC2 instance in us-east-1 so network latency to Hyperliquid and Binance is minimised.
  - **Acceptance criteria:**
    - AC-021-1: Docker Compose stack deploys cleanly on `Ubuntu 24.04 LTS` on `c6i.xlarge` in `us-east-1`.
    - AC-021-2: Engine process runs as an unprivileged system user (`cex-engine`).
    - AC-021-3: EBS `gp3` volume is mounted at `/app/data` for SQLite persistence across instance reboots.
    - AC-021-4: Order submission p99 latency to HL API is under 30 ms measured from the EC2 instance.
    - AC-021-5: Security group allows only inbound SSH (port 22) and the dashboard port (3000) from the operator IP.

- [ ] **PP-ITEM-11.2**
  - **ID:** US-022
  - **Title:** EC2 health check and auto-restart
  - **Description:** As the operator, I want the engine to restart automatically if it crashes so I do not need to manually intervene for transient failures.
  - **Acceptance criteria:**
    - AC-022-1: `docker compose` `restart: unless-stopped` policy is set for both `engine` and `control` services.
    - AC-022-2: Engine health check is triggered every 5 s; unhealthy after 10 retries (50 s).
    - AC-022-3: A Telegram notification is sent whenever the engine restarts (via the IPC event `event.engine.restarted`).
    - AC-022-4: `scripts/verify.sh` runs cleanly from the EC2 instance, confirming build, typecheck, and service health.

---

## Development task plan

### Phase 1 — Codebase pruning and project setup

- [ ] **TASK-1.1** Delete Polymarket-specific Zig source files
  - [ ] TASK-1.1.1: Delete `zig/src/polymarket_auth.zig`
  - [ ] TASK-1.1.2: Delete `zig/src/gamma_api.zig`
  - [ ] TASK-1.1.3: Delete `zig/src/kalshi_ws.zig`
  - [ ] TASK-1.1.4: Delete `zig/src/news_sources.zig`
  - [ ] TASK-1.1.5: Delete `zig/src/market_scanner.zig`
  - [ ] TASK-1.1.6: Delete `zig/src/probability_provider.zig`
  - [ ] TASK-1.1.7: Delete `zig/src/clob_orderbook.zig`
  - [ ] TASK-1.1.8: Remove all `@import` references to deleted files from `main.zig` and `tests.zig`

- [ ] **TASK-1.2** Update environment variable schema
  - [ ] TASK-1.2.1: Remove `POLYMARKET_PRIVATE_KEY`, `POLYMARKET_SIGNATURE_TYPE`, `POLYMARKET_FUNDER_ADDRESS`, `KALSHI_API_KEY` from `.env.example`
  - [ ] TASK-1.2.2: Add `HL_API_PRIVATE_KEY`, `HL_MAIN_WALLET_ADDRESS`, `HL_NETWORK` (default `testnet`), `BINANCE_ASSETS` (comma-separated, e.g. `BTC,ETH`), `DRY_RUN` to `.env.example`
  - [ ] TASK-1.2.3: Update `docker-compose.yml` `environment:` blocks for both services

- [ ] **TASK-1.3** Update `zig/build.zig` and `zig.zon`
  - [ ] TASK-1.3.1: Remove module declarations for all deleted source files
  - [ ] TASK-1.3.2: Add module declarations for all new source files listed in the architecture section
  - [ ] TASK-1.3.3: Confirm `zig build` produces no errors on a clean tree

### Phase 2 — MsgPack encoder and HL signing (FR-01, FR-02, US-003, US-004)

- [ ] **TASK-2.1** Implement `zig/src/msgpack.zig`
  - [ ] TASK-2.1.1: Implement MsgPack fixmap encoder for the HL Order struct field set
  - [ ] TASK-2.1.2: Implement string, integer, float, and boolean type encoders
  - [ ] TASK-2.1.3: Ensure field ordering matches the HL canonical order exactly
  - [ ] TASK-2.1.4: Write 10 unit test vectors comparing output to known-good Python `msgpack` output
  - [ ] TASK-2.1.5: Benchmark: assert encode time < 5 µs on the EC2 instance

- [ ] **TASK-2.2** Implement `zig/src/hl_auth.zig`
  - [ ] TASK-2.2.1: Load `HL_API_PRIVATE_KEY` from environment; validate 64-char hex; derive address using existing `crypto.deriveAddress()`
  - [ ] TASK-2.2.2: Define the HL EIP-712 domain: `name="Exchange"`, `chainId=1337` (mainnet) or the testnet chain ID; `verifyingContract=HL_EXCHANGE_ADDR`
  - [ ] TASK-2.2.3: Implement `buildOrderDigest(order, chainId)`: `keccak256(msgpack(action)) → EIP-712 hash`
  - [ ] TASK-2.2.4: Implement `signOrder(digest, privkey)` returning `{r, s, v}` using `crypto.signEip712()`
  - [ ] TASK-2.2.5: Write unit tests: known order struct produces known digest; signature verifies against derived address
  - [ ] TASK-2.2.6: Manual integration test: submit a signed order to testnet `/exchange` and confirm acceptance

### Phase 3 — Asset index and market data (FR-03, FR-06, FR-07, FR-08, US-005, US-006)

- [ ] **TASK-3.1** Implement `zig/src/hl_market_meta.zig`
  - [ ] TASK-3.1.1: POST `{"type":"meta"}` to `/info` on startup; parse `universe` JSON array
  - [ ] TASK-3.1.2: Build in-memory `StringHashMap(u32)` mapping symbol to asset index
  - [ ] TASK-3.1.3: Implement `getAssetIndex(symbol) → ?u32` lookup
  - [ ] TASK-3.1.4: Schedule a 24-hour refresh timer to call the same fetch
  - [ ] TASK-3.1.5: Persist asset index to `markets` table on each fetch (migration required)
  - [ ] TASK-3.1.6: Unit tests: parse a fixture `meta` response; verify index lookup correctness

- [ ] **TASK-3.2** Implement `zig/src/hl_orderbook.zig`
  - [ ] TASK-3.2.1: Connect to `wss://api.hyperliquid[-testnet].xyz/ws`; send `{"method":"subscribe","subscription":{"type":"l2Book","coin":"BTC"}}`
  - [ ] TASK-3.2.2: Parse the initial snapshot: build two sorted arrays (bids descending, asks ascending) of `{price, size}` pairs
  - [ ] TASK-3.2.3: Apply delta messages: insert new levels, update existing, remove zero-size levels
  - [ ] TASK-3.2.4: Expose `getBestBid()`, `getBestAsk()`, `getMid()` inline functions
  - [ ] TASK-3.2.5: Implement reconnect with exponential backoff; re-subscribe and re-ingest snapshot on reconnect
  - [ ] TASK-3.2.6: Benchmark delta application; log if > 50 µs (warning, not error)
  - [ ] TASK-3.2.7: Persist mid-price snapshots to `orderbooks` table (reuse existing schema; add `asset_index` column via migration)
  - [ ] TASK-3.2.8: Unit tests: fixture snapshot ingestion; fixture delta application for insert, update, delete

- [ ] **TASK-3.3** Implement `zig/src/binance_ws.zig`
  - [ ] TASK-3.3.1: Connect to `wss://fstream.binance.com/ws/<symbol>@bookTicker` for each asset in `BINANCE_ASSETS`
  - [ ] TASK-3.3.2: Parse `bookTicker` JSON: extract `b` (best bid), `a` (best ask); compute mid; record nanosecond timestamp
  - [ ] TASK-3.3.3: Expose `getMid(asset) → ?{mid: f64, ts_ns: i128}` thread-safe getter
  - [ ] TASK-3.3.4: Implement reconnect with 2s fixed delay; if down > 30s, pause arb strategy and alert via IPC
  - [ ] TASK-3.3.5: Unit tests: parse a fixture `bookTicker` message; verify mid computation

### Phase 4 — Order placement and cancellation (FR-04, FR-05, US-008, US-009)

- [ ] **TASK-4.1** Implement `zig/src/hl_order_manager.zig`
  - [ ] TASK-4.1.1: Implement `placeOrder(asset_index, is_buy, price, size, order_type, reduce_only, tif)` → `OrderResult`
  - [ ] TASK-4.1.2: Build the `{"action":{"type":"order","orders":[...],"grouping":"na"},"nonce":<ms>,"signature":{r,s,v}}` JSON payload
  - [ ] TASK-4.1.3: POST to `/exchange`; parse response for `order_id`; persist to `orders` table
  - [ ] TASK-4.1.4: Implement retry with backoff (7 retries, 1s base, 60s cap) on 429 and 5xx responses
  - [ ] TASK-4.1.5: Log `order_submit_ts` for every order
  - [ ] TASK-4.1.6: Implement `cancelOrder(asset_symbol, order_id)` using `"cancel"` action type
  - [ ] TASK-4.1.7: Implement `cancelAll()` — fetch all open orders from `orders` table; cancel each
  - [ ] TASK-4.1.8: Implement `halt()` — set halted flag; call `cancelAll()`; emit `event.engine.halted` IPC event
  - [ ] TASK-4.1.9: Unit tests: order payload JSON structure; retry logic; halt behaviour

- [ ] **TASK-4.2** Dry-run order interception layer
  - [ ] TASK-4.2.1: Check `DRY_RUN` flag at the top of `placeOrder()`; if set, write to `dry_run_orders` and return a synthetic `order_id`
  - [ ] TASK-4.2.2: Simulate latency using a uniform random delay between 8ms and 25ms before recording the simulated placement
  - [ ] TASK-4.2.3: Dry-run cancel: update `dry_run_orders.status = 'cancelled'` only; no API call
  - [ ] TASK-4.2.4: Ensure dry-run and live code paths share the same risk gate and signal pipeline

### Phase 5 — Fill detection and portfolio tracking (FR-11, FR-12, US-010, US-011)

- [ ] **TASK-5.1** Implement `zig/src/hl_fill_poller.zig`
  - [ ] TASK-5.1.1: Subscribe to the HL user WebSocket with API Wallet credentials
  - [ ] TASK-5.1.2: Handle `fills` events: update `orders` table status; write to `fills` table; emit `event.order.filled` IPC event
  - [ ] TASK-5.1.3: Handle `orderUpdates` events for partial fills and cancellations
  - [ ] TASK-5.1.4: Log `fill_ts` (nanosecond) for latency tracking; compute `fill_ts − submit_ts` per order
  - [ ] TASK-5.1.5: Implement REST polling fallback: query HL `/info` `{"type":"openOrders","user":"<addr>"}` every 5 s if WS is down
  - [ ] TASK-5.1.6: Dry-run simulation: every 30 s, scan `dry_run_orders` where `status=open`; check l2Book; settle fills; update balance

- [ ] **TASK-5.2** Implement `zig/src/hl_portfolio_tracker.zig`
  - [ ] TASK-5.2.1: Poll `{"type":"clearinghouseState","user":"<MAIN_WALLET>"}` every 60 s
  - [ ] TASK-5.2.2: Parse `marginSummary.accountValue`; write to `balance_snapshots`
  - [ ] TASK-5.2.3: Parse `assetPositions`; write to `positions` table with `mark_price`, `unrealised_pnl`, `funding_accrued`
  - [ ] TASK-5.2.4: Expose `getSnapshot()` for IPC `portfolio` handler
  - [ ] TASK-5.2.5: Implement `writeSnapshotJson()` with HL field names (equity, margin_used, funding_accrued)
  - [ ] TASK-5.2.6: If equity fetch fails 3×, pause strategy evaluation and publish `event.engine.paused` via IPC

### Phase 6 — Risk gate and strategy engine (FR-09, FR-10, FR-15, FR-16, US-012, US-013, US-014, US-015)

- [ ] **TASK-6.1** Rewrite `zig/src/risk_gate.zig` for margin model
  - [ ] TASK-6.1.1: Replace `queryOpenExposureUsd()` with `queryOpenNotionalUsd()` — sum of `position_size × mark_price` per open position
  - [ ] TASK-6.1.2: Add `checkMarginLeverage(order_notional, account_equity, max_leverage_pct)` check as the primary position limit
  - [ ] TASK-6.1.3: Remove duplicate-position check (not applicable to perps — same asset can be added to an existing position)
  - [ ] TASK-6.1.4: Add `checkFundingRateAdverse(asset, current_rate, max_rate)` check for LP orders
  - [ ] TASK-6.1.5: Update `validatePairPreflight()` to use notional model
  - [ ] TASK-6.1.6: Update all unit tests in `tests.zig` to use the new margin semantics

- [ ] **TASK-6.2** Update `zig/src/strategy_engine.zig`
  - [ ] TASK-6.2.1: Rename `liquidity_provision` strategy to `market_making` in enums and log messages
  - [ ] TASK-6.2.2: Update LP default config: `lp_min_spread=0.0005`, `lp_order_size_pct=0.05`
  - [ ] TASK-6.2.3: Add `StrategyName.cex_dex_arb` enum variant
  - [ ] TASK-6.2.4: Implement inventory skew check in `evaluateLiquidityProvision()`: after fill, suppress bids and skew ask down
  - [ ] TASK-6.2.5: Add `checkInventorySkew(market_id) → SkewState` returning `{ suppress_bids: bool, ask_offset_bps: f64 }`
  - [ ] TASK-6.2.6: Update `getInventorySnapshot()` IPC handler with HL terminology

- [ ] **TASK-6.3** Implement `zig/src/cex_dex_arb.zig`
  - [ ] TASK-6.3.1: Implement `computeDelta(binance_mid, hl_mid) → {delta_bps: f64, ts_ns: i128}`
  - [ ] TASK-6.3.2: Implement trigger: fire taker order when `abs(delta_bps) >= arb_threshold_bps` and stable for `arb_confirm_ms`
  - [ ] TASK-6.3.3: Implement circuit breaker: count consecutive losing arb trades; disable after 5; re-enable after 30 min
  - [ ] TASK-6.3.4: Write arb event to `arb_events` table with full latency breakdown
  - [ ] TASK-6.3.5: Expose `evaluateCexDexArb(asset, binance_mid, hl_mid) → ?Signal`
  - [ ] TASK-6.3.6: Unit tests: delta computation; trigger logic; circuit breaker state machine

### Phase 7 — Database migrations (FR-18)

- [ ] **TASK-7.1** Write migration 012 — HL market fields
  - [ ] TASK-7.1.1: `ALTER TABLE markets DROP COLUMN clob_token_ids` (SQLite: recreate table)
  - [ ] TASK-7.1.2: `ALTER TABLE markets DROP COLUMN condition_id, neg_risk`
  - [ ] TASK-7.1.3: `ALTER TABLE markets ADD COLUMN asset_index INTEGER DEFAULT -1`
  - [ ] TASK-7.1.4: `ALTER TABLE markets ADD COLUMN base_asset TEXT DEFAULT ''`
  - [ ] TASK-7.1.5: `ALTER TABLE markets ADD COLUMN max_leverage INTEGER DEFAULT 20`

- [ ] **TASK-7.2** Write migration 013 — positions and orders HL fields
  - [ ] TASK-7.2.1: `ALTER TABLE positions ADD COLUMN mark_price REAL DEFAULT 0.0`
  - [ ] TASK-7.2.2: `ALTER TABLE positions ADD COLUMN funding_accrued REAL DEFAULT 0.0`
  - [ ] TASK-7.2.3: `ALTER TABLE positions ADD COLUMN leverage INTEGER DEFAULT 1`
  - [ ] TASK-7.2.4: `ALTER TABLE orders ADD COLUMN asset_index INTEGER DEFAULT -1`
  - [ ] TASK-7.2.5: `ALTER TABLE orders ADD COLUMN reduce_only INTEGER DEFAULT 0`

- [ ] **TASK-7.3** Write migration 014 — new tables
  - [ ] TASK-7.3.1: Create `funding_snapshots` table with columns: `id`, `asset`, `rate`, `next_payment_ts`, `snapshot_at`
  - [ ] TASK-7.3.2: Create `arb_events` table with columns: `id`, `asset`, `binance_mid`, `hl_mid`, `delta_bps`, `order_id`, `realised_pnl`, `submit_ns`, `fill_ns`, `created_at`
  - [ ] TASK-7.3.3: Add `funding_charge` and `simulated_slippage` columns to `dry_run_orders`

- [ ] **TASK-7.4** Embed migrations in `db.zig` and update `runMigrations()`
  - [ ] TASK-7.4.1: Add `MIGRATION_012`, `MIGRATION_013`, `MIGRATION_014` constants
  - [ ] TASK-7.4.2: Add `migrationApplied(12)`, `migrationApplied(13)`, `migrationApplied(14)` checks
  - [ ] TASK-7.4.3: Add `DB.insertArbEvent()`, `DB.insertFundingSnapshot()`, `DB.queryArbEvents(limit)` helper methods

### Phase 8 — IPC, Telegram, and dashboard (FR-19, FR-31–FR-34, US-018–US-020)

- [ ] **TASK-8.1** Update `zig/src/ipc_types.zig`
  - [ ] TASK-8.1.1: Remove `kalshi.mappings`, `kalshi.mappings.response` message types
  - [ ] TASK-8.1.2: Add `funding.snapshot`, `funding.snapshot.response`, `arb.events`, `arb.events.response` message types
  - [ ] TASK-8.1.3: Update `StrategyName` type references: rename `liquidity_provision` → `market_making`, add `cex_dex_arb`
  - [ ] TASK-8.1.4: Update `PortfolioPayload` interface: replace `usdc_balance` with `equity`, add `margin_used_pct`, `funding_accrued`

- [ ] **TASK-8.2** Update `zig/src/ipc.zig` dispatch table
  - [ ] TASK-8.2.1: Remove `kalshi_mappings` and `config_validate` dispatch entries
  - [ ] TASK-8.2.2: Add `funding_snapshot` and `arb_events` dispatch handlers
  - [ ] TASK-8.2.3: Update `handleStrategyList()` to include `cex_dex_arb` strategy stats

- [ ] **TASK-8.3** Update TypeScript IPC types (`ts/src/ipc/types.ts`)
  - [ ] TASK-8.3.1: Mirror all changes from `ipc_types.zig` on the TypeScript side
  - [ ] TASK-8.3.2: Add `FundingSnapshotPayload`, `ArbEventPayload` interfaces
  - [ ] TASK-8.3.3: Remove `KalshiMappingInfo`, `KalshiMappingsResponsePayload`

- [ ] **TASK-8.4** Update Telegram bot (`ts/src/telegram/bot.ts`)
  - [ ] TASK-8.4.1: Add `/funding` command handler (US-018)
  - [ ] TASK-8.4.2: Add `/arb` command handler (US-019)
  - [ ] TASK-8.4.3: Remove `/mappings`, `/drystatus` old format; update `/drystatus` for per-strategy breakdown (US-017)
  - [ ] TASK-8.4.4: Add `TESTNET` / `MAINNET` badge to `/status` and `/livestatus` output
  - [ ] TASK-8.4.5: Remove all Polymarket/Kalshi/Gamma references from help text and command responses
  - [ ] TASK-8.4.6: Add push event handler for `event.arb.triggered` (new event type)

- [ ] **TASK-8.5** Update web dashboard (`ts/src/components/Dashboard.tsx`)
  - [ ] TASK-8.5.1: Replace `USDC Balance` KPI card with `Account Equity` card using `equity` field
  - [ ] TASK-8.5.2: Add `Margin Used (%)` KPI card
  - [ ] TASK-8.5.3: Update positions table columns: add `mark_price`, `funding_accrued`; remove `entry_price` display distortion from perp semantics
  - [ ] TASK-8.5.4: Rename Market Tracker to show Binance mid, HL mid, spread (bps), l2Book staleness
  - [ ] TASK-8.5.5: Add `TESTNET` (orange) / `MAINNET` (green) environment badge in the page header
  - [ ] TASK-8.5.6: Remove all Polymarket/Kalshi/Gamma label strings from UI

### Phase 9 — Testing and dry-run validation

- [ ] **TASK-9.1** Unit test suite updates
  - [ ] TASK-9.1.1: Remove all Polymarket/Kalshi-specific test cases from `zig/src/tests.zig`
  - [ ] TASK-9.1.2: Add msgpack encoder tests (10 vectors against known output)
  - [ ] TASK-9.1.3: Add HL signing tests (known order → known digest → signature verifies)
  - [ ] TASK-9.1.4: Add l2Book snapshot and delta application tests
  - [ ] TASK-9.1.5: Add arb strategy delta computation and trigger logic tests
  - [ ] TASK-9.1.6: Add margin risk gate tests with account equity and leverage scenarios
  - [ ] TASK-9.1.7: Add inventory skew test: fill event triggers bid suppression
  - [ ] TASK-9.1.8: Add migration 012–014 tests (table exists, columns present)
  - [ ] TASK-9.1.9: Run `zig build test` to 100% pass rate before testnet deployment

- [ ] **TASK-9.2** Testnet dry-run validation (7-day paper trading period)
  - [ ] TASK-9.2.1: Deploy to EC2 with `HL_NETWORK=testnet`, `DRY_RUN=1`; enable both strategies
  - [ ] TASK-9.2.2: Monitor `/drystatus` daily; record fill rate, win rate, P&L per strategy
  - [ ] TASK-9.2.3: Confirm LP paper net P&L is positive over 7 days
  - [ ] TASK-9.2.4: Confirm arb paper win rate ≥ 55% over 7 days
  - [ ] TASK-9.2.5: Measure order submission latency p99 from EC2 to HL testnet
  - [ ] TASK-9.2.6: Confirm fill detection latency p99 < 500 ms
  - [ ] TASK-9.2.7: Confirm no naked positions occur (all LP buys have paired sell within 5 s)
  - [ ] TASK-9.2.8: Confirm inventory skew correctly suppresses bids after a fill event

- [ ] **TASK-9.3** Latency benchmarking
  - [ ] TASK-9.3.1: Instrument `submit_ns` (signal generated) and `ack_ns` (API response received) per order
  - [ ] TASK-9.3.2: Log `arb_delta_ns = hl_submit_ns − binance_event_ns` per arb event
  - [ ] TASK-9.3.3: Run `scripts/verify.sh` on EC2; confirm p99 order latency < 30 ms

### Phase 10 — Documentation, deployment, and maintenance

- [ ] **TASK-10.1** Update `README.md`
  - [ ] TASK-10.1.1: Rewrite the Architecture section for the HL module layout
  - [ ] TASK-10.1.2: Update Environment Variables table: remove Polymarket vars; add HL vars
  - [ ] TASK-10.1.3: Update Quick Start for testnet dry-run workflow: testnet setup, faucet link, verification steps
  - [ ] TASK-10.1.4: Update the Phase Map table to reflect the HL development milestones
  - [ ] TASK-10.1.5: Add Latency Tuning section documenting EC2 placement and WS connection settings
  - [ ] TASK-10.1.6: Add Promotion to Live section: checklist from testnet dry-run to mainnet live

- [ ] **TASK-10.2** Update `docker-compose.yml` and Dockerfiles
  - [ ] TASK-10.2.1: Add `HL_NETWORK`, `HL_API_PRIVATE_KEY`, `HL_MAIN_WALLET_ADDRESS`, `BINANCE_ASSETS` to `Dockerfile.engine` env documentation
  - [ ] TASK-10.2.2: Remove `ENABLE_NEWS_REPRICING`, `ENABLE_LIQUIDITY_PROVISION` env vars; replace with `ENABLE_MARKET_MAKING`, `ENABLE_CEX_DEX_ARB`
  - [ ] TASK-10.2.3: Update healthcheck to verify l2Book WebSocket is connected (check a flag file or IPC heartbeat)

- [ ] **TASK-10.3** Operational runbooks
  - [ ] TASK-10.3.1: Write `docs/testnet-setup.md`: HL testnet account creation, API Wallet setup, faucet USDC request, first dry-run
  - [ ] TASK-10.3.2: Write `docs/go-live-checklist.md`: 7-day paper trading gate, mainnet `.env` changes, first-hour monitoring steps
  - [ ] TASK-10.3.3: Write `docs/latency-tuning.md`: EC2 instance placement, kernel TCP settings, WS reconnect config

- [ ] **TASK-10.4** Maintenance schedule
  - [ ] TASK-10.4.1: Schedule weekly review of arb circuit breaker trips and LP P&L
  - [ ] TASK-10.4.2: Set a calendar reminder to check HL API changelog for breaking changes monthly
  - [ ] TASK-10.4.3: Confirm DB retention ticker prunes `arb_events` and `funding_snapshots` older than 30 days
  - [ ] TASK-10.4.4: Automate `.env` secret rotation reminder every 90 days for `HL_API_PRIVATE_KEY`

---

## Traceability matrix

| Functional requirement | User story | Acceptance criteria |
|------------------------|------------|---------------------|
| FR-01 MsgPack encoder | US-003 | AC-003-1 to AC-003-4 |
| FR-02 HL API Wallet auth | US-001 | AC-001-1 to AC-001-4 |
| FR-03 Asset index fetch | US-005 | AC-005-1 to AC-005-5 |
| FR-04 Order placement | US-008 | AC-008-1 to AC-008-5 |
| FR-05 Order cancellation | US-009 | AC-009-1 to AC-009-4 |
| FR-06/07/08 l2Book WebSocket | US-006 | AC-006-1 to AC-006-6 |
| FR-09/10 Risk gate margin model | US-012 | AC-012-1 to AC-012-5 |
| FR-11 Portfolio tracking | US-011 | AC-011-1 to AC-011-5 |
| FR-12 Fill detection | US-010 | AC-010-1 to AC-010-5 |
| FR-13/14 Dry-run testnet | US-016 | AC-016-1 to AC-016-7 |
| FR-15 Inventory skew | US-013 | AC-013-1 to AC-013-4 |
| FR-16 LP tight spread | US-014 | AC-014-1 to AC-014-5 |
| FR-21 Binance WS | US-007 | AC-007-1 to AC-007-5 |
| FR-22/23/24 Arb strategy | US-015 | AC-015-1 to AC-015-6 |
| FR-25/26 Arb telemetry/CB | US-015 | AC-015-5, AC-015-6 |
| FR-27 Funding rate fetch | US-018 | AC-018-1 to AC-018-4 |
| FR-34 Dry-run P&L report | US-017 | AC-017-1 to AC-017-5 |
| FR-31 Dashboard HL labels | US-020 | AC-020-1 to AC-020-5 |
| FR-32 /funding command | US-018 | AC-018-1 to AC-018-4 |
| FR-33 /arb command | US-019 | AC-019-1 to AC-019-4 |
| Non-functional: latency | US-021 | AC-021-4 |
| Non-functional: uptime | US-022 | AC-022-1 to AC-022-4 |
| Non-functional: testnet/mainnet toggle | US-002 | AC-002-1 to AC-002-5 |

---

## Open questions

- [ ] **Q-001**: What is the Hyperliquid testnet chain ID for EIP-712 domain construction? The mainnet uses `1337`; the testnet chain ID must be confirmed from the HL developer docs before TASK-2.2.2 can be closed. **Owner:** Owen. **Decision needed by:** before Milestone 1 gate.

- [ ] **Q-002**: Does the HL user WebSocket require the main wallet address or the API Wallet address for authentication? The mainnet docs suggest the API Wallet, but this must be confirmed on testnet before TASK-5.1.1. **Owner:** Owen. **Decision needed by:** before Milestone 3 gate.

- [ ] **Q-003**: What is the minimum order size (in contracts/USD notional) on HL for the assets we intend to trade? This affects `lp_order_fallback_usd` and `arb_max_size_usd` default values. **Owner:** Owen. **Decision needed by:** before TASK-6.2.2.

- [ ] **Q-004**: Should the arb strategy place reduce-only taker orders (to flatten an existing LP position) or always open new positions? This affects the `reduce_only` flag on arb orders and the risk gate behaviour. **Owner:** Owen. **Decision needed by:** before TASK-6.3.1.

- [ ] **Q-005**: Is a Terraform module for EC2 provisioning (FR-40) in scope for this phase, or should it be deferred to a subsequent hardening phase? The current plan treats it as P2. **Owner:** Owen. **Decision needed by:** before Phase 10.

---

## Quality assurance checklist

- [ ] Every user story has a unique ID and testable acceptance criteria
- [ ] User stories cover primary workflows (US-008), alternative paths (US-009 cancel), and edge cases (US-012 margin limit, US-013 skew)
- [ ] Authentication requirements addressed in US-001, US-002, US-004
- [ ] Milestones have clear gate conditions and realistic week-level estimates
- [ ] Development tasks are specific, actionable, and ordered by dependency
- [ ] Backend tasks (Zig) and frontend tasks (TypeScript) are paired for each feature
- [ ] All ten development phases are present: setup (Phase 1), signing foundation (Phase 2), market data (Phase 3), order management (Phase 4), portfolio (Phase 5), risk/strategy (Phase 6), database (Phase 7), IPC/dashboard (Phase 8), testing (Phase 9), documentation/deployment (Phase 10)
- [ ] Technical considerations address margin model semantics, MsgPack correctness, latency from EC2 us-east-1, and dry-run parity with live