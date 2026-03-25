**PRODUCT REQUIREMENTS DOCUMENT**

**Polymarket Autonomous Trading Bot**

Telegram-controlled · Self-monitoring · Profit-seeking · Low-Latency

Version 1.1 · March 2026

**Status: Draft**

# **Document information**

| **Document title**  | Polymarket Autonomous Trading Bot - Product Requirements Document |
| ------------------- | ----------------------------------------------------------------- |
| **Version**         | 1.1                                                               |
| **Status**          | Draft                                                             |
| **Date**            | March 2026                                                        |
| **Author**          | Engineering / Product Team                                        |
| **Reviewers**       | Lead Engineer, Risk Officer, QA Lead                              |
| **Primary API**     | Polymarket CLOB API + Gamma API                                   |
| **Chain**           | Polygon (chain ID 137), USDC collateral                           |
| **Control surface** | Telegram Bot (TypeScript + Grammy) & Web Dashboard                |
| **Core Engine**     | Zig (Custom CLOB/Gamma HTTP & WS implementation)                  |
| **Deployment**      | AWS EC2 (Ubuntu 24.04 LTS or Amazon Linux 2023)                   |

# **1\. Executive summary**

This document specifies the requirements for a fully autonomous, low-latency prediction market trading bot that operates on Polymarket. The system discovers markets on Polymarket's Gamma API, evaluates them using configurable trading strategies, places and manages orders through the CLOB API (on Polygon).

To maximize latency gains and system performance, the **core trading engine is written in Zig**. To provide a rich, asynchronous control surface, the **operator interface is a Node.js/TypeScript Telegram bot using the Grammy framework**, accompanied by a **simple Web Dashboard** for real-time monitoring. The entire multi-process architecture is designed to be deployed onto a single AWS EC2 instance.

**Core thesis:** Polymarket is an information-efficient but not always price-efficient prediction market. Systematic, rules-based strategies can generate positive expected value. By implementing the core engine in a systems language (Zig), the bot can react to WebSocket price updates and news triggers in single-digit milliseconds, capturing edge before slower Python or Node.js-based participants.

# **2\. Goals and non-goals**

## **2.1 Business & Performance goals**

* **BG-01** Generate consistent positive returns on deployed USDC capital through autonomous Polymarket trading.
* **BG-02** Preserve capital - no single position or day should risk more than configurable drawdown limits.
* **BG-03** Operate autonomously for extended periods (days to weeks) on an EC2 instance without operator intervention.
* **BG-04** Achieve ultra-low latency (< 10ms) from WebSocket event to order dispatch via the Zig engine.

## **2.2 User goals**

* **UG-01** Know at a glance whether the bot is running, profitable, and within risk limits via Telegram.
* **UG-02** Receive a push notification via Telegram whenever a trade is placed, filled, or a risk limit is breached.
* **UG-03** Query portfolio state, open orders, and historical P&L at any time via a Telegram command.
* **UG-04** Change strategy parameters and intervene securely from a mobile device via Telegram.
* **UG-05** Trust that the bot will not exceed configured risk limits under any market condition.
* **UG-06** **[NEW]** Monitor active trades, live P&L, and system health via a simple, real-time Web Dashboard from any browser.

## **2.3 Explicit non-goals**

* **NG-01** Support for exchanges or prediction markets other than Polymarket.
* **NG-03** Social trading, copy trading, or sharing positions with other users.
* **NG-04** Leveraged positions (Polymarket is naturally unleveraged; no synthetic leverage).
* **NG-06** Legal, tax, or compliance advice; the operator is responsible for jurisdiction-specific obligations.
* *(Note: Former NG-02 regarding UI has been removed to accommodate the new Web Dashboard).*

# **3\. User personas**

## **3.1 Solo operator (primary)**

| **Role**            | Runs and owns the bot; sole user of the Telegram interface.                                                          |
| ------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Technical level** | High - writes Python, understands order books and probability, comfortable with Polygon/USDC.                        |
| **Primary need**    | A bot that makes money while they sleep, with enough visibility to trust it and enough control to stop it instantly. |
| **Pain point**      | Spending hours monitoring markets manually; missing opportunities; having no visibility when away.                   |
| **Access level**    | Full - all Telegram commands, including halt, config changes, and manual order placement.                            |

## **3.2 Risk-conscious operator (secondary)**

| **Role**            | Operator who prioritises capital preservation over maximum returns.                              |
| ------------------- | ------------------------------------------------------------------------------------------------ |
| **Technical level** | Moderate - monitors via Telegram, adjusts config; does not modify code. Relies on TS Dashboard for visualization.                          |
| **Primary need**    | Hard limits on drawdown and position size; daily digest of activity; alerts on anything unusual. |
| **Pain point**      | Automated systems that run unchecked until a catastrophic loss.                                  |
| **Access level**    | Full Telegram access; config editable via /config command; code is read-only to them.            |

## **3.3 Developer / maintainer (tertiary)**

| **Role**            | Extends, debugs, and deploys the bot.                                                          |
| ------------------- | ---------------------------------------------------------------------------------------------- |
| **Technical level** | Expert - full code access, deploys to VPS or cloud, manages secrets.                           |
| **Primary need**    | Clean, modular codebase; easy to add new strategies; observable internals via structured logs. Understands core is in Zig. |
| **Pain point**      | Monolithic bots with no separation of concerns that break silently.                            |
| **Access level**    | Full - source code, environment variables, server.                                             |

# **4\. System architecture overview**

The system is deployed on a single AWS EC2 instance and is divided into two main processes communicating via **UNIX Domain Sockets** for maximum IPC throughput and minimum latency, alongside a shared SQLite database (in WAL mode).

## **4.1 Core Engine (Zig)**

Highly optimized, compiled binary responsible for all latency-sensitive operations.

* **Market scanner:** Polls Gamma API. Maintains an in-memory market registry. Subscribes to CLOB WebSockets.
* **Strategy engine:** Evaluates markets against pluggable strategies natively compiled in Zig.
* **Order manager:** Enforces position limits. Places, monitors, amends, and cancels orders via the CLOB API.
* **Risk gate:** Standalone validation layer. Rejects non-compliant orders.
* **Portfolio tracker:** Maintains real-time state.
* **Local Control Server:** Exposes a lightning-fast **UNIX Domain Socket API** for the TypeScript layer to read in-memory state, subscribe to event streams, and issue commands (e.g., `/halt`, `/trade`).

## **4.2 Interface Layer (TypeScript / Node.js)**

Handles user interactions, external webframes, and webhooks.

* **Telegram Interface (Grammy):** Listens to inbound Telegram commands, dispatches queries to the Zig core over the UNIX socket, and listens for event payloads from Zig to send push notifications. **This is the exclusive control surface for the bot.**
* **Web Dashboard (Express/Fastify + React/Vue):** A simple web application served on a specific port. Fetches real-time portfolio, order, and P&L data from the SQLite DB and Zig UNIX socket. **Strictly read-only for metrics and visualization.**

# **5\. Functional requirements**

*(Sections 5.1 through 5.5 remain functionally identical, with the technical distinction that all execution, risk gating, and CLOB API interactions are implemented in Zig rather than `py-clob-client`.)*

## **5.1 Market scanning and discovery**

| **ID** | **Requirement**                                                                                                                                                                   | **Priority** | **Notes**                        |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | -------------------------------- |
| FR-01  | The scanner shall poll the Gamma API every N minutes (configurable, default 10) to discover active markets.                                                                       | **P0**       | gamma-api.polymarket.com/markets |
| FR-02  | Markets shall be filtered by: minimum 24h volume (default \$5,000), minimum liquidity (default \$1,000), maximum time-to-resolution (default 30 days), and optional category tag. | **P0**       | Configurable filters             |
| FR-03  | The scanner shall fetch live BBO (best bid/offer), mid-price, and order book depth for all tracked markets from the CLOB API.                                                     | **P0**       | clob.polymarket.com              |
| FR-04  | The scanner shall subscribe to the CLOB WebSocket feed for real-time price updates on all tracked markets.                                                                        | **P0**       | Live price feed                  |
| FR-05  | Markets resolved within the last scan cycle shall be detected, their positions redeemed if applicable, and a notification sent.                                                   | **P0**       | Auto-redemption                  |
| FR-06  | The operator shall be able to manually add or blacklist a market by slug via Telegram command.                                                                                    | **P1**       | /market add \| blacklist         |
| FR-07  | A negative risk opportunity (complementary No tokens summing to > \$1.00) shall be flagged and a conversion opportunity sent to the operator.                                     | **P1**       | Neg-risk detection               |

## **5.2 Trading strategies**

Strategies are pluggable Python classes implementing a common interface (evaluate(market) -> Signal | None). Multiple strategies may be active simultaneously.

| **ID** | **Requirement**                                                                                                                                                                                                                          | **Priority** | **Notes**                              |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | -------------------------------------- |
| FR-08  | Strategy: News repricing - when a major news event moves the consensus probability on external sources (Metaculus, PredictIt, Kalshi) more than X% away from Polymarket's mid-price, place a directional limit order to capture the lag. | **P0**       | Requires news API                      |
| FR-09  | Strategy: Liquidity provision (market making) - post limit buy and sell orders symmetrically around the mid-price on markets with wide spreads (> configured threshold), collecting the spread.                                          | **P0**       | GTC limit orders                       |
| FR-10  | Strategy: Mean reversion - when a market's price deviates more than N% from its 24h rolling average without a corresponding news trigger, place a fading limit order.                                                                    | **P1**       | Requires price history                 |
| FR-11  | Strategy: Resolution edge - when a market is within 48h of resolution and its current price differs meaningfully from the operator-configured fair value, place a directional trade.                                                     | **P1**       | Manual fair value input                |
| FR-12  | Strategy: Volume spike - when a market's 1h volume exceeds its 7d average volume by a configurable multiple, flag the market for operator review and optionally place a momentum trade.                                                  | **P2**       | Volume anomaly                         |
| FR-13  | Each active strategy shall be independently enable/disable-able via Telegram without restarting the bot.                                                                                                                                 | **P0**       | /strategy enable\|disable &lt;name&gt; |
| FR-14  | Strategy signals shall include: market_id, direction (YES/NO), price, size_usd, order_type (GTC/FOK/FAK), confidence score (0-1), and signal source.                                                                                     | **P0**       | Signal struct                          |
| FR-15  | All strategy evaluation runs and emitted signals shall be written to the database and queryable via Telegram.                                                                                                                            | **P1**       | Audit trail                            |

## **5.3 Order management (Updated)**

| **ID** | **Requirement** | **Priority** | **Notes** |
| --- | --- | --- | --- |
| FR-16 | The order manager (Zig) shall place limit orders directly via the Polymarket CLOB REST API, constructing and signing EIP-712 messages natively. | **P0** | Natively in Zig |
| FR-23 | The order manager shall respect CLOB API rate limits and implement exponential back-off on 429 responses. | **P0** | Rate limit handling |

## **5.4 Risk gate**

| **ID** | **Requirement**                                                                                                                                 | **Priority** | **Notes**            |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | -------------------- |
| FR-25  | Every order must pass through the risk gate before submission; the gate is not bypassable by any code path.                                     | **P0**       | Mandatory gate       |
| FR-26  | Risk check: per-trade notional ≤ max_position_usd (configurable, default \$500).                                                                | **P0**       | Position size limit  |
| FR-27  | Risk check: total open position notional across all markets ≤ max_portfolio_exposure_usd (configurable, default \$5,000).                       | **P0**       | Portfolio exposure   |
| FR-28  | Risk check: daily realised + unrealised loss ≤ max_daily_drawdown_usd (configurable, default \$200).                                            | **P0**       | Daily drawdown       |
| FR-29  | Risk check: total open orders across all markets ≤ max_open_orders (configurable, default 20).                                                  | **P0**       | Order count limit    |
| FR-30  | Risk check: no duplicate position in the same market and direction (no pyramiding unless configured).                                           | **P1**       | Duplicate guard      |
| FR-31  | When any risk check fails, the rejection is logged with the specific check name and values, and a Telegram alert is sent.                       | **P0**       | Rejection visibility |
| FR-32  | Risk parameters shall be hot-reloadable via /config set command without restarting the bot.                                                     | **P0**       | Hot reload           |
| FR-33  | An emergency kill-switch (/halt) shall immediately cancel all open orders and disable all strategy evaluation for the remainder of the session. | **P0**       | /halt command        |

## **5.5 Portfolio tracking**

| **ID** | **Requirement**                                                                                                                                                       | **Priority** | **Notes**          |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ------------------ |
| FR-34  | The portfolio tracker shall maintain real-time state of all open positions, pending orders, USDC balance, and unrealised P&L by subscribing to CLOB WebSocket events. | **P0**       | WebSocket feed     |
| FR-35  | Realised P&L shall be calculated on each fill as: (fill_price - entry_price) × size − fees.                                                                           | **P0**       | P&L accounting     |
| FR-36  | CLOB taker fee (default 2 bps) and maker fee shall be factored into all P&L calculations and signal profitability thresholds.                                         | **P0**       | Fee-aware          |
| FR-37  | The portfolio tracker shall persist all positions, fills, and balance snapshots to SQLite.                                                                            | **P0**       | SQLite persistence |
| FR-38  | Positions in resolved markets shall be automatically redeemed using the CLOB redeem endpoint; proceeds shall be recorded.                                             | **P0**       | Auto-redeem        |
| FR-39  | A daily portfolio snapshot (balance, open positions, realised P&L, win rate) shall be generated and sent to Telegram at a configurable time (default 00:00 UTC).      | **P0**       | Daily digest       |

## **5.6 Telegram bot interface (TypeScript / Grammy)**

All Telegram commands are accessible only to the configured operator chat ID(s). The bot rejects all messages from unknown users.

| **ID** | **Requirement** | **Priority** | **Notes** |
| --- | --- | --- | --- |
| FR-40 | `/status` - fetches from Zig API: uptime, active strategies, USDC balance, open positions, unrealised P&L, daily P&L, risk gate status. | **P0** | Health overview |
| FR-41 | `/portfolio` - returns a formatted table of all open positions. | **P0** | Position view |
| FR-48 | `/config get` - reads configuration values from the shared config file or DB. | **P0** | Config read |
| FR-49 | `/config set <key> <value>` - TS bot sends update to Zig API; the risk gate applies the new value immediately. | **P0** | Config write |
| FR-54 | `/halt` - TS bot sends emergency halt to Zig API. Zig immediately cancels all orders and disables strategies. | **P0** | Emergency halt |
| FR-56 | Push notifications sent proactively via Grammy bot when Zig engine triggers a webhook for: order filled, risk limit, etc. | **P0** | Proactive alerts |

## **5.7 Web Dashboard [NEW]**

| **ID** | **Requirement** | **Priority** | **Notes** |
| --- | --- | --- | --- |
| FR-63 | The TypeScript app shall serve a **strictly read-only** Web Dashboard over HTTP/HTTPS, protected by basic authentication or a secure token. | **P0** | Dashboard Auth |
| FR-64 | The Dashboard shall display real-time USDC balance, total portfolio exposure, daily P&L, and an active list of open orders and positions. | **P0** | Portfolio UI |
| FR-65 | The Dashboard shall include a "System Log" panel that streams the recent structured logs from the Zig engine. | **P1** | Log streaming |
| FR-66 | The Dashboard shall display a list of all currently tracked markets with their live mid-price and spread. | **P1** | Market Tracker UI |
| FR-67 | The Dashboard shall expose **zero control surfaces**. All state changes (pause, halt, parameter tuning, manual trading) must be executed via the authenticated Telegram bot to minimize the web attack surface. | **P0** | Security Boundary |

## **5.8 Configuration and persistence**

| **ID** | **Requirement** | **Priority** | **Notes** |
| --- | --- | --- | --- |
| FR-58 | Configuration stored in a `config.yaml` file loaded by both Zig and TS layers. Secrets handled via `.env` variables on the EC2 instance. | **P0** | Config file |
| FR-60 | All persistent data is written to a local SQLite database configured in WAL (Write-Ahead Logging) mode to allow concurrent reading by the TS Dashboard/Bot and writing by the Zig engine. | **P0** | SQLite WAL |

# **6\. Non-functional requirements**

| **ID** | **Category** | **Requirement** | **Target** |
| --- | --- | --- | --- |
| NFR-01 | **Latency** | Time from WebSocket price event to strategy evaluation & Zig order dispatch | **< 10 ms** |
| NFR-02 | **Latency** | Time from TS Grammy command receipt to Zig API response | < 50 ms |
| NFR-03 | **Latency** | Time from fill event received to Telegram notification sent | < 2 s |
| NFR-04 | **Reliability** | EC2 instance / process uptime excluding planned restarts | \> 99% |
| NFR-07 | **Safety** | No order placement without passing Zig risk gate (zero exceptions) | Enforced natively |
| NFR-10 | **Security** | Dashboard and Telegram bot reject all unauthorized access | Auth enforcement |
| NFR-14 | **Portability** | Runs as systemd services on AWS EC2 (Ubuntu 24.04 or AL2023) | EC2 targeted |
| NFR-15 | **Maintainability** | Clean separation of concerns: Zig for speed/core logic, TS for UI/UX | Micro-architecture |

# **7\. User experience narrative**

## **7.1 Setup and Deployment**

The operator provisions an AWS EC2 instance. They clone the repository, run an install script that compiles the Zig engine (`zig build -Doptimize=ReleaseFast`) and installs the Node.js dependencies for the interface layer. They configure their `.env` with their Polygon private key and Telegram Bot token. The system starts via `systemd` (one service for the Zig engine, one for the TS UI layer).

## **7.2 Dashboard Monitoring**

While at their desk, the operator navigates to `http://<ec2-ip>:<port>`, logs in, and views the Dashboard. They see the Zig engine aggressively updating order book spreads in single-digit milliseconds without locking up the UI, thanks to the decoupled TS backend fetching data smoothly via the local API.

## **7.3 Telegram Intervention**

Later, while out for dinner, the operator receives a push notification via Telegram that a stop-loss has triggered. They type `/status` to see their current balance, and decide to type `/pause` to halt trading for the rest of the evening. The TS bot instantly relays this to the Zig engine via the local API, which cancels open limits and pauses evaluation.

# **8\. Milestones and sequencing**

**Team size:** 1-2 engineers (Systems/Zig + Fullstack/TS). **Total estimate:** 8 weeks.

| **Phase** | **Milestone** | **Duration** | **Deliverables** |
| --- | --- | --- | --- |
| **Phase 0** | Infrastructure & IPC Foundation | Week 1 | EC2 setup scripts, Zig project structure, TS project structure, SQLite WAL setup, local HTTP/Socket IPC between Zig and Node. |
| **Phase 1** | Zig Core: Market Data & Client | Week 2 | Zig Gamma API poller, CLOB native HTTP/WS clients, EIP-712 signing natively in Zig. |
| **Phase 2** | Zig Core: Risk Gate & Orders | Week 3 | Order placement engine, 5 risk checks, order staleness tracking, SQLite persistence layer in Zig. |
| **Phase 3** | Zig Core: Strategies | Week 4 | Strategy evaluation loop in Zig, news_repricing and liquidity_provision strategies. |
| **Phase 4** | TS Interface: Telegram Bot | Week 5 | Grammy bot setup, webhook listener for Zig events, `/status`, `/portfolio`, `/orders` commands. |
| **Phase 5** | TS Interface: Bot Control | Week 6 | `/config set`, `/trade`, `/halt`, `/pause` commands routed to Zig API. Approval mode inline keyboards. |
| **Phase 6** | TS Interface: Web Dashboard | Week 7 | Express/React read-only dashboard, real-time portfolio tables, system log streaming, Basic Auth wrapper. |
| **Phase 7** | Deployment & Hardening | Week 8 | End-to-end integration testing, systemd configuration for EC2, latency profiling, README. |

# **9\. Success metrics**

## **9.1 Financial**

* Positive 30-day realised P&L net of all CLOB fees.
* Win rate ≥ 50% of closed positions over any 30-day period.

## **9.2 Operational**

* Bot uptime > 99% on EC2.
* Zero unhandled crashes in the Zig core (strict memory safety enforced).
* Dashboard loads in < 1s and updates seamlessly without straining the core trading loop.

## **9.3 Technical**

* **Latency goal achieved:** Strategy evaluation pipeline completes within 10 ms of a WebSocket price event (measured via Zig tracing).
* No database locks between the Zig write-path and TS read-path.

# **10\. Architectural Decisions & Open Questions**

## **10.1 Resolved Architectural Decisions**

* **AD-001 (IPC Mechanism):** Communication between the Zig core engine and the TypeScript interface layer will be handled via **UNIX Domain Sockets**. This avoids the overhead of the local TCP/IP stack, providing the latency gains necessary for the high-performance Zig engine while allowing seamless data flow to the Node.js frontend.
* **AD-002 (Control Surface Separation):** The Web Dashboard is designed strictly for **metrics and visualization**. To maintain a tight security perimeter and minimize the web-facing attack surface, all bot control features (e.g., `/halt`, `/trade`, config modifications) are strictly cordoned off to the Telegram bot interface.

## **10.2 Open Questions**

| **Q-001** | EIP-712 signing in Zig will require implementing or importing a fast `keccak256`/`secp256k1` library. Which C/Zig library is the most reliable and audited for this purpose? |
| --- | --- |

# **11\. Risks and mitigations**

| **Risk**                       | **Impact**                                                                                     | **Mitigation**                                                                                                |
| ------------------------------ | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Capital loss**               | A strategy has negative edge and erodes capital systematically before drawdown limits trigger. | Hard daily drawdown limit; --dry-run period of ≥ 7 days before live capital; paper trading P&L tracking.      |
| **CLOB API downtime**          | Polymarket CLOB is unavailable; open positions cannot be managed.                              | Circuit breaker pauses new orders; operator alerted; existing GTC orders remain on-book.                      |
| **WebSocket disconnect**       | Live price feed drops; strategy engine acts on stale prices.                                   | Heartbeat monitor; reconnect with exponential back-off; stale price guard rejects signals older than 30 s.    |
| **Polygon network congestion** | On-chain settlement delayed; fills reported late.                                              | Polling fallback for order status; fee estimation buffer; not relying on sub-minute settlement.               |
| **Private key compromise**     | Bot wallet drained by attacker.                                                                | Key stored only as env var; minimal on-chain balance (top up as needed); spending allowances set per session. |
| **Strategy overfitting**       | Backtested strategy performs poorly on live markets.                                           | Out-of-sample validation required before enabling live; confidence thresholds; position size limits.          |
| **Telegram API rate limits**   | Bot is rate-limited by Telegram; notifications delayed.                                        | Notification queue with batching; critical alerts (halt, stop-loss) use high-priority send.                   |
| **Market manipulation**        | Thin market is manipulated; strategy enters at manipulated price.                              | Minimum liquidity filter on market scanner; order book depth check before placement.                          |

# **12\. Requirements traceability matrix**

| **FR / NFR**        | **User story** | **Acceptance criteria**         |
| ------------------- | -------------- | ------------------------------- |
| FR-01, FR-02        | US-001         | AC-01, AC-02, AC-03             |
| FR-03, FR-04        | US-001         | AC-04, AC-05                    |
| FR-05, FR-38        | US-002         | AC-01, AC-02                    |
| FR-06               | US-003         | AC-01, AC-02                    |
| FR-07               | US-010         | AC-01                           |
| FR-08               | US-004         | AC-01, AC-02, AC-03             |
| FR-09               | US-005         | AC-01, AC-02, AC-03             |
| FR-10, FR-11, FR-12 | US-006         | AC-01, AC-02                    |
| FR-13, FR-14, FR-15 | US-006, US-007 | AC-01, AC-02, AC-03             |
| FR-16, FR-17, FR-18 | US-008         | AC-01, AC-02, AC-03             |
| FR-19, FR-20, FR-21 | US-009         | AC-01, AC-02, AC-03             |
| FR-22, FR-23, FR-24 | US-008         | AC-04, AC-05                    |
| FR-25 to FR-31      | US-011         | AC-01 to AC-05                  |
| FR-32, FR-33        | US-011         | AC-06, AC-07                    |
| FR-34, FR-35, FR-36 | US-002         | AC-03, AC-04                    |
| FR-37, FR-39        | US-002, US-015 | AC-05, AC-01                    |
| FR-40               | US-012         | AC-01, AC-02                    |
| FR-41, FR-42        | US-013         | AC-01, AC-02, AC-03             |
| FR-43               | US-014         | AC-01, AC-02, AC-03             |
| FR-44, FR-45        | US-003         | AC-03, AC-04                    |
| FR-46, FR-47        | US-007         | AC-04, AC-05                    |
| FR-48, FR-49        | US-016         | AC-01, AC-02                    |
| FR-50, FR-51, FR-52 | US-008, US-017 | AC-01, AC-02                    |
| FR-53, FR-54        | US-017         | AC-03, AC-04                    |
| FR-55, FR-56        | US-012, US-015 | AC-03, AC-04                    |
| FR-57               | US-018         | AC-01, AC-02                    |
| FR-58 to FR-62      | US-016         | AC-03, AC-04, AC-05             |
| NFR-07              | US-011         | Risk gate mandatory - no bypass |
| NFR-09, NFR-11      | US-019         | AC-01, AC-02                    |
| NFR-10              | US-019         | AC-03                           |
| NFR-17, NFR-18      | US-017         | AC-05, AC-06                    |

# **13\. User stories**

All user stories use the personas defined in section 3. Each story has a unique ID and numbered, testable acceptance criteria.

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-001 Market discovery and live price tracking P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>have the bot automatically discover liquid, active Polymarket markets and track their live prices,</p><p><strong>so that </strong>the strategy engine always has current price data without any manual market selection.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given the scanner runs, it returns only markets where 24h volume ≥ min_volume_usd config and liquidity ≥ min_liquidity_usd config.</li><li><strong>AC-02: </strong>Given a market's time-to-resolution exceeds max_resolution_days config, it is excluded from the tracked list.</li><li><strong>AC-03: </strong>Given the scanner discovers a new market, it is added to the tracked list and a log entry is written.</li><li><strong>AC-04: </strong>Given a tracked market has a WebSocket subscription active, the strategy engine receives a price update within 500 ms of a CLOB price change.</li><li><strong>AC-05: </strong>Given the WebSocket disconnects, the bot reconnects automatically within 30 s and sends a Telegram warning.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-002 Position tracking and automatic redemption P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>have the bot automatically track all positions and redeem winnings when markets resolve,</p><p><strong>so that </strong>I never leave capital stranded in resolved markets and my P&amp;L is always accurate.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given a market resolves YES, any open YES position is automatically redeemed and proceeds added to USDC balance.</li><li><strong>AC-02: </strong>Given a redemption succeeds, a Telegram notification is sent with the market name and proceeds.</li><li><strong>AC-03: </strong>The portfolio tracker reflects the correct unrealised P&amp;L within 10 s of a fill event.</li><li><strong>AC-04: </strong>CLOB taker and maker fees are correctly deducted from all P&amp;L calculations.</li><li><strong>AC-05: </strong>All fills and balance changes are persisted to SQLite within 1 s of the fill event.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-003 Manual market management via Telegram P1</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>add or remove markets from the scanner and view their current state via Telegram,</p><p><strong>so that </strong>I can focus the bot on the markets I have conviction in and exclude those I want to avoid.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given /market add &lt;slug&gt;, the market is added to the tracked list immediately and a confirmation message is sent.</li><li><strong>AC-02: </strong>Given /market blacklist &lt;slug&gt;, the market is removed from tracking and no signals are generated for it.</li><li><strong>AC-03: </strong>Given /markets, the bot returns a formatted list of all tracked markets with slug, YES mid-price, spread, and 24h volume.</li><li><strong>AC-04: </strong>Given /market &lt;slug&gt;, the bot returns the order book top 5 bids/asks, my open position, and active orders for that market.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-004 News repricing strategy P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>have the bot automatically detect when Polymarket prices lag external consensus and place directional trades,</p><p><strong>so that </strong>I can capture the value of being faster than the average Polymarket participant in reacting to news.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given a configured external probability source shows a probability more than edge_threshold% different from Polymarket's mid-price, the strategy emits a signal.</li><li><strong>AC-02: </strong>The signal direction is: BUY if external &gt; Polymarket, SELL if external &lt; Polymarket.</li><li><strong>AC-03: </strong>The signal price is set at mid_price ± half_spread to give a reasonable fill probability.</li><li><strong>AC-04: </strong>Given the external probability returns to within threshold of Polymarket's price before fill, the strategy cancels the pending order.</li><li><strong>AC-05: </strong>All signals are logged with source, external probability, Polymarket probability, and edge.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-005 Liquidity provision strategy P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>have the bot automatically post buy and sell limit orders around the mid-price on wide-spread markets,</p><p><strong>so that </strong>I can earn the spread on markets with sufficient volume without taking directional risk.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given a market's current spread &gt; min_spread_for_mm config, the strategy posts a buy order at mid - quote_offset and a sell order at mid + quote_offset.</li><li><strong>AC-02: </strong>Given one side fills, the other side is cancelled to avoid adverse selection on a directional move.</li><li><strong>AC-03: </strong>Given the market spread narrows below the threshold, any open market-making orders for that market are cancelled.</li><li><strong>AC-04: </strong>The position size per side respects max_position_usd config.</li><li><strong>AC-05: </strong>The strategy does not post orders if the unrealised position in the market already exceeds max_position_usd.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-006 Additional trading strategies P1</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>have mean reversion and resolution edge strategies available alongside the core strategies,</p><p><strong>so that </strong>I can deploy capital across a broader set of edges and reduce reliance on any single strategy.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given a market's current price deviates &gt; mean_reversion_threshold% from its 24h rolling average and no news event is detected, the mean reversion strategy emits a fading signal.</li><li><strong>AC-02: </strong>Given a market is within resolution_window_hours of resolution and the operator has set a fair value, the resolution edge strategy emits a signal if current price differs by &gt; edge_threshold%.</li><li><strong>AC-03: </strong>Each strategy tracks its own signal count, fill rate, and realised P&amp;L independently.</li><li><strong>AC-04: </strong>Strategies are independently enabled and disabled via Telegram without restarting the bot.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-007 Strategy monitoring via Telegram P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>see which strategies are running, how many signals they have emitted, and their historical performance,</p><p><strong>so that </strong>I can understand which strategies are contributing to profitability and disable underperforming ones.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given /strategy list, the bot returns: strategy name, enabled/disabled, signal count today, fill rate, and realised P&amp;L for the current period.</li><li><strong>AC-02: </strong>Given /strategy disable &lt;name&gt;, the strategy stops evaluating markets immediately and no further signals are emitted.</li><li><strong>AC-03: </strong>Given /strategy enable &lt;name&gt;, the strategy resumes evaluation on the next scanner cycle.</li><li><strong>AC-04: </strong>Strategy state changes are logged and a Telegram confirmation is sent.</li><li><strong>AC-05: </strong>Historical signal data is queryable from SQLite and summarised in /pnl output.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-008 Autonomous order placement and management P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>have the bot place, monitor, and cancel orders autonomously without requiring my involvement,</p><p><strong>so that </strong>the bot can operate profitably overnight and across weekends without me checking in.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given a validated signal, a limit order is placed via CLOB API within 1 s and the order ID is persisted.</li><li><strong>AC-02: </strong>Given a FOK market order is specified by the strategy, it is placed immediately and not retried if unfilled.</li><li><strong>AC-03: </strong>Given a GTC order has been open for longer than max_order_age_hours, it is cancelled and a Telegram notification is sent.</li><li><strong>AC-04: </strong>Given the CLOB API returns HTTP 429, the bot backs off exponentially (1 s, 2 s, 4 s… up to 60 s) before retrying.</li><li><strong>AC-05: </strong>All order events (placed, filled, partially filled, cancelled) trigger a Telegram push notification within 5 s.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-009 Stop-loss and take-profit automation P0</strong></p></th></tr><tr><td><p><strong>As a </strong>risk-conscious operator,</p><p><strong>I want to </strong>have the bot automatically exit positions that have lost too much or gained enough to lock in profit,</p><p><strong>so that </strong>my capital is protected even when I am not watching the bot.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given a position's unrealised loss ≥ stop_loss_pct × entry notional, a FOK market sell order is placed immediately.</li><li><strong>AC-02: </strong>Given a position's unrealised gain ≥ take_profit_pct × entry notional, a GTC limit sell order is placed at current mid.</li><li><strong>AC-03: </strong>Stop-loss triggers send a Telegram push notification with the exit price and realised P&amp;L.</li><li><strong>AC-04: </strong>Stop-loss and take-profit thresholds are configurable per-strategy and globally via /config set.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-010 Negative risk opportunity detection P1</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>be notified when a set of No tokens in a multi-outcome market can be profitably converted,</p><p><strong>so that </strong>I can capture risk-free (or near-risk-free) returns from market mispricings in multi-outcome events.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given an event where the sum of No token prices across all outcomes exceeds $1.00, the scanner flags it as a negative risk opportunity.</li><li><strong>AC-02: </strong>A Telegram alert is sent with the event name, No token prices, and estimated profit after fees.</li><li><strong>AC-03: </strong>If auto_neg_risk is enabled, the bot executes the conversion automatically via the CLOB convert endpoint.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-011 Mandatory risk gate enforcement P0</strong></p></th></tr><tr><td><p><strong>As a </strong>risk-conscious operator,</p><p><strong>I want to </strong>be certain that the bot never places an order that violates my configured risk limits,</p><p><strong>so that </strong>I can trust the bot with real capital knowing it has hard limits that cannot be bypassed.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given a signal where notional &gt; max_position_usd, the order is rejected, logged with reason 'MaxPositionExceeded', and a Telegram alert is sent.</li><li><strong>AC-02: </strong>Given total open position notional &gt; max_portfolio_exposure_usd, all new orders are rejected until exposure decreases.</li><li><strong>AC-03: </strong>Given daily realised + unrealised loss &gt; max_daily_drawdown_usd, all strategy evaluation is paused and the operator is alerted.</li><li><strong>AC-04: </strong>Given open orders count &gt; max_open_orders, new signals are queued until an order closes.</li><li><strong>AC-05: </strong>There is no code path, command, or flag that bypasses the risk gate (except manual orders via /trade, which still pass through all risk checks).</li><li><strong>AC-06: </strong>Risk parameters take effect immediately after /config set; no restart required.</li><li><strong>AC-07: </strong>Given /halt, all open orders are cancelled within 10 s and strategy evaluation is disabled until /resume.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-012 Real-time bot status via Telegram P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>get an instant summary of the bot's health, positions, and P&amp;L from Telegram at any time,</p><p><strong>so that </strong>I can assess the bot's state in seconds without looking at logs or a dashboard.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given /status, the bot responds within 3 s with: uptime, active strategies (count and names), USDC balance, open position count, unrealised P&amp;L, today's realised P&amp;L, and risk gate status (green/red).</li><li><strong>AC-02: </strong>Given /status when the bot is paused (after /pause or /halt), the response clearly indicates the bot is not trading.</li><li><strong>AC-03: </strong>All values in /status are current within 10 s of the query.</li><li><strong>AC-04: </strong>If the USDC balance is below low_balance_threshold config, /status includes a warning flag.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-013 Portfolio and order visibility via Telegram P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>see my open positions and pending orders formatted clearly in Telegram,</p><p><strong>so that </strong>I have full visibility into what the bot holds and has committed capital to.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given /portfolio, the bot returns a table of all open positions: market slug (truncated), direction, entry price, current price, size in shares, notional, unrealised P&amp;L ($ and %).</li><li><strong>AC-02: </strong>Given /orders, the bot returns all open orders: market, direction, limit price, size, age since placement, and order type.</li><li><strong>AC-03: </strong>Given no open positions, /portfolio returns 'No open positions' - not an empty table or error.</li><li><strong>AC-04: </strong>Tables are formatted to be readable in Telegram's monospace font.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-014 P&amp;L reporting via Telegram P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>query my realised P&amp;L for different time windows and see win/loss statistics,</p><p><strong>so that </strong>I can assess whether the bot is meeting its financial goals.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given /pnl today, the bot returns: realised P&amp;L, number of closed positions, win count, loss count, average win size, average loss size.</li><li><strong>AC-02: </strong>Given /pnl 7d, /pnl 30d, and /pnl all, equivalent reports for the respective windows are returned.</li><li><strong>AC-03: </strong>All P&amp;L figures are net of CLOB fees.</li><li><strong>AC-04: </strong>Given no closed positions in the window, the bot returns 'No closed positions in this period' with the current unrealised P&amp;L.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-015 Proactive push notifications P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>receive unprompted Telegram notifications for all significant bot events,</p><p><strong>so that </strong>I am always aware of what the bot is doing even when I am not actively checking it.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>The bot sends a push notification for each of: order placed, order filled (partial or full), order cancelled (staleness), stop-loss triggered, take-profit triggered, risk gate rejection, market resolved, daily digest.</li><li><strong>AC-02: </strong>Notifications are sent within 5 s of the triggering event.</li><li><strong>AC-03: </strong>Given USDC balance drops below low_balance_threshold, a warning notification is sent immediately.</li><li><strong>AC-04: </strong>Given any unhandled exception occurs, the stack trace is logged and a Telegram error notification is sent.</li><li><strong>AC-05: </strong>Given the Telegram API is unavailable, notifications are queued and delivered when connectivity resumes; no notification is permanently lost.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-016 Runtime configuration via Telegram P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>view and change all bot parameters via Telegram without restarting the bot,</p><p><strong>so that </strong>I can tune risk limits and strategy parameters in response to market conditions without touching the server.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given /config get, the bot returns all current config values formatted as a readable list (secrets redacted).</li><li><strong>AC-02: </strong>Given /config set max_position_usd 250, the new value takes effect immediately and the risk gate uses it on the next evaluation.</li><li><strong>AC-03: </strong>Given /config set with an invalid value (e.g. a string for a numeric field, or a value out of allowed range), the bot rejects the change and returns an error message.</li><li><strong>AC-04: </strong>Config changes are logged with old value, new value, timestamp, and operator.</li><li><strong>AC-05: </strong>Secrets (POLY_PRIVATE_KEY, TELEGRAM_BOT_TOKEN) are not displayed in /config get output.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-017 Manual trade and emergency control via Telegram P0</strong></p></th></tr><tr><td><p><strong>As a </strong>solo operator,</p><p><strong>I want to </strong>place manual trades and instantly pause or halt the bot via Telegram,</p><p><strong>so that </strong>I retain full control at all times and can intervene in seconds if something goes wrong.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given /trade &lt;slug&gt; YES 0.55 200, a limit order is placed at $0.55 for $200 notional after passing the risk gate.</li><li><strong>AC-02: </strong>Given /cancel &lt;order_id&gt;, the specific order is cancelled and a confirmation is sent.</li><li><strong>AC-03: </strong>Given /cancel all, all open orders are cancelled within 10 s and a summary is sent.</li><li><strong>AC-04: </strong>Given /pause, strategy evaluation stops immediately; existing orders remain open; /resume re-enables evaluation.</li><li><strong>AC-05: </strong>Given /halt, all orders are cancelled within 10 s and strategies are disabled; /resume is required to restart.</li><li><strong>AC-06: </strong>Given the bot is halted, any strategy signal is discarded silently until /resume is issued.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-018 Approval mode for semi-autonomous operation P1</strong></p></th></tr><tr><td><p><strong>As a </strong>risk-conscious operator,</p><p><strong>I want to </strong>have the bot prompt me for approval before placing each trade via Telegram inline buttons,</p><p><strong>so that </strong>I can review every trade decision before capital is committed while still benefiting from automated signal generation.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given approval_mode: true in config, the bot sends a Telegram message with trade details and Approve / Reject inline keyboard buttons.</li><li><strong>AC-02: </strong>Given the operator taps Approve within 60 s, the order is placed immediately.</li><li><strong>AC-03: </strong>Given the operator taps Reject, the signal is discarded and a rejection log entry is written.</li><li><strong>AC-04: </strong>Given no response within 60 s, the signal expires and a timeout notification is sent.</li><li><strong>AC-05: </strong>In approval mode, the bot can still autonomously cancel stale orders and trigger stop-losses without approval.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-019 Security and key isolation P0</strong></p></th></tr><tr><td><p><strong>As a </strong>developer / maintainer,</p><p><strong>I want to </strong>be certain that the private key never leaks into logs, Telegram messages, or the database,</p><p><strong>so that </strong>a log file or Telegram history leak does not result in wallet compromise.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given any log event, the private key string does not appear in any field of the JSON log output.</li><li><strong>AC-02: </strong>Given any Telegram message sent by the bot, the private key string does not appear in the message text.</li><li><strong>AC-03: </strong>Given a SQLite query of all tables, the private key string does not appear in any row.</li><li><strong>AC-04: </strong>The Telegram bot ignores all messages from chat IDs not in the TELEGRAM_CHAT_ID allow list and does not respond or log the message content.</li></ol></td></tr></tbody></table></div>
