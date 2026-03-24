**PRODUCT REQUIREMENTS DOCUMENT**

**Zig CEX Arbitrage Bot**

Cross-Exchange Spread Detection & Alert Engine

Version 1.0 · March 2026

**Status: Draft**

# **Document information**

| **Document title** | Zig CEX Arbitrage Bot - Product Requirements Document |
| ------------------ | ----------------------------------------------------- |
| **Version**        | 1.0                                                   |
| **Status**         | Draft                                                 |
| **Date**           | March 2026                                            |
| **Author**         | Engineering Team                                      |
| **Reviewers**      | Engineering Lead, Risk Officer, QA Lead               |

# **1\. Executive summary**

This document specifies the requirements for a production-grade, cross-exchange cryptocurrency arbitrage bot written in Zig. The system monitors live bid/offer (BBO) data across multiple centralised exchanges (CEXs), identifies price discrepancies that exceed a configurable profit threshold, validates each opportunity against a mandatory risk gate, and delivers real-time alerts to configured notification channels.

**Why Zig?** Zig provides deterministic memory management, no hidden allocator behaviour, explicit error handling with typed error unions, and comptime evaluation - making it well-suited for latency-sensitive financial tooling where undefined behaviour, hidden allocations, and unchecked errors are unacceptable.

**Why rewrite?** The reference C++ implementation (arber.bot.cpp) contains several critical defects: sequential REST polling with a single worker thread serialises latency across exchanges, the risk manager is entirely commented out, concurrent state is accessed without synchronisation, and profit-threshold enforcement is disabled. The Zig rewrite corrects all of these and introduces a channel-based, parallel-fetch architecture.

# **2\. Goals and non-goals**

## **2.1 Business goals**

- **BG-01** Detect cross-exchange arbitrage opportunities with end-to-end latency under 500 ms.
- **BG-02** Enforce a configurable minimum profit threshold before any alert is dispatched.
- **BG-03** Enforce risk limits (exposure, drawdown, volatility) as a mandatory, non-bypassable gate.
- **BG-04** Deliver alerts to Slack and Discord with enough context to act within seconds.
- **BG-05** Produce structured logs and latency metrics observable via standard tooling.
- **BG-06** Support adding new exchanges with minimal code changes (single new file).

## **2.2 User goals**

- **UG-01** Receive accurate, timely alerts when a profitable spread exists.
- **UG-02** Understand why an alert was or was not fired (structured log output).
- **UG-03** Configure the bot without recompiling (environment variables and config file).
- **UG-04** Trust that the risk gate cannot be silently disabled or bypassed.

## **2.3 Explicit non-goals**

- **NG-01** Order execution - the bot detects and alerts; it does not place trades.
- **NG-02** Decentralised exchange (DEX) support.
- **NG-03** Portfolio management or position tracking.
- **NG-04** Machine learning or predictive models.
- **NG-05** A graphical user interface.
- **NG-06** Custodial key management or signing.

# **3\. User personas**

## **3.1 Quantitative trader (primary)**

| **Role**            | Runs or manages algorithmic trading strategies on CEXs.                                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Technical level** | High - reads logs, understands order books, interprets spread metrics.                                                                                         |
| **Primary need**    | Receive a Slack/Discord alert the moment a tradeable spread opens, with enough context (buy exchange, sell exchange, profit %, notional size) to act manually. |
| **Pain point**      | False positives from stale prices or insufficient spread after fees wipe out the opportunity.                                                                  |
| **Access level**    | Configures and runs the bot; reads all logs and alerts.                                                                                                        |

## **3.2 Risk officer (secondary)**

| **Role**            | Sets risk parameters and monitors exposure.                                                                                    |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **Technical level** | Moderate - reads dashboards and logs; does not write code.                                                                     |
| **Primary need**    | Confidence that no alert fires unless all risk checks pass. Clear log output when an opportunity is rejected by the risk gate. |
| **Pain point**      | Risk configuration that can be silently commented out or overridden in code.                                                   |
| **Access level**    | Edits risk configuration file; reads risk-rejected log events.                                                                 |

## **3.3 Developer / operator (tertiary)**

| **Role**            | Maintains, extends, and operates the bot.                                                                                          |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **Technical level** | Expert - writes Zig, understands async I/O, deploys to bare metal or VPS.                                                          |
| **Primary need**    | A clean, testable codebase with explicit errors, zero undefined behaviour, and straightforward extension points for new exchanges. |
| **Pain point**      | Hidden allocations, data races, and magic that breaks silently under load.                                                         |
| **Access level**    | Full source access; manages deployment and secrets.                                                                                |

# **4\. Functional requirements**

## **4.1 Price fetching**

| **ID** | **Requirement**                                                                                                                | **Priority** | **Notes**                |
| ------ | ------------------------------------------------------------------------------------------------------------------------------ | ------------ | ------------------------ |
| FR-01  | The system shall fetch BBO data from Binance, ByBit, Coinbase, and OKX simultaneously on separate threads.                     | **P0**       | Parallel, not sequential |
| FR-02  | Each fetcher shall use a persistent HTTP/1.1 connection with TCP keep-alive.                                                   | **P0**       | Zig std.http.Client      |
| FR-03  | Each fetcher shall enforce a per-request timeout configurable via config (default 500 ms).                                     | **P0**       | No hardcoded value       |
| FR-04  | Fetcher errors shall be logged at WARN level and the fetcher shall retry after a configurable back-off (default 1 s).          | **P0**       | Error union propagation  |
| FR-05  | Each BBO update shall carry an exchange identifier, a token pair, bid/ask price and size, and a monotonic fetch timestamp.     | **P0**       | BboUpdate struct         |
| FR-06  | The system shall support WebSocket-based price feeds as an alternative to REST polling, selectable per exchange in config.     | **P1**       | Phase 2 feature          |
| FR-07  | A new exchange shall be addable by implementing a single Gateway interface, without modifying the engine or any existing file. | **P1**       | comptime dispatch        |

## **4.2 Arbitrage engine**

| **ID** | **Requirement**                                                                                                                                         | **Priority** | **Notes**                 |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ------------------------- |
| FR-08  | The engine shall maintain a per-exchange BBO state table, updated on every incoming BboUpdate.                                                          | **P0**       | State table, not re-fetch |
| FR-09  | On each state update, the engine shall evaluate all N\*(N-1) exchange pairs for the current token pair.                                                 | **P0**       | O(n²) spread check        |
| FR-10  | An opportunity is valid if and only if: sell_bid > buy_ask AND profit_pct >= min_profit_config.                                                         | **P0**       | Both conditions required  |
| FR-11  | The engine shall emit only the single best opportunity per evaluation cycle (highest profit_pct).                                                       | **P0**       | Best, not first           |
| FR-12  | The engine shall track the exchange name, token pair, profit %, notional amount (capped at configurable max), buy BBO, and sell BBO for each candidate. | **P0**       | ArbOpportunity struct     |
| FR-13  | The engine shall run on a dedicated thread and communicate with fetchers via a bounded channel.                                                         | **P0**       | Decoupled from I/O        |

## **4.3 Risk gate**

| **ID** | **Requirement**                                                                                                  | **Priority** | **Notes**               |
| ------ | ---------------------------------------------------------------------------------------------------------------- | ------------ | ----------------------- |
| FR-14  | Every candidate opportunity must pass through the risk gate before an alert is dispatched.                       | **P0**       | Mandatory, not optional |
| FR-15  | The risk gate shall reject any opportunity where the notional amount exceeds max_exposure_per_trade config.      | **P0**       | MaxExposure strategy    |
| FR-16  | The risk gate shall reject any opportunity where the current portfolio drawdown exceeds max_drawdown_pct config. | **P0**       | DrawdownStrategy        |
| FR-17  | The risk gate shall reject any opportunity where 24-hour rolling volatility exceeds max_volatility config.       | **P1**       | VolatilityStrategy      |
| FR-18  | A rejected opportunity shall be logged at INFO level with the rejection reason.                                  | **P0**       | Observability           |
| FR-19  | Risk metrics shall be updated on a configurable interval (default 5 s) on a separate thread.                     | **P0**       | Not blocking engine     |
| FR-20  | Risk configuration shall be readable from a file and hot-reloadable via SIGHUP.                                  | **P1**       | No restart required     |

## **4.4 Alert dispatch**

| **ID** | **Requirement**                                                                                                                                                                                        | **Priority** | **Notes**             |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------ | --------------------- |
| FR-21  | Approved opportunities shall be sent to a bounded alert channel consumed by one or more notifier workers.                                                                                              | **P0**       | Non-blocking engine   |
| FR-22  | The Slack notifier shall POST to a configurable webhook URL with a message containing: token pair, buy exchange, sell exchange, profit %, notional amount, buy price, sell price, and fetch timestamp. | **P0**       | Full context in alert |
| FR-23  | The Discord notifier shall POST to a configurable webhook URL with the same fields as the Slack notifier.                                                                                              | **P0**       | Parity with Slack     |
| FR-24  | Notifier failures shall be logged at ERROR level and retried once after 2 s. Persistent failure shall not crash the bot.                                                                               | **P0**       | Resilience            |
| FR-25  | New notifiers shall be addable by implementing a Notifier interface without modifying existing code.                                                                                                   | **P1**       | Observer pattern      |

## **4.5 Configuration**

| **ID** | **Requirement**                                                                                                                  | **Priority** | **Notes**         |
| ------ | -------------------------------------------------------------------------------------------------------------------------------- | ------------ | ----------------- |
| FR-26  | All runtime parameters shall be configurable via a TOML config file loaded at startup.                                           | **P0**       | Config-driven     |
| FR-27  | Secrets (webhook URLs, API keys) shall be loadable from environment variables and shall take precedence over config file values. | **P0**       | Twelve-factor app |
| FR-28  | The bot shall validate config at startup and exit with a descriptive error if required fields are missing or out of range.       | **P0**       | Fail fast         |
| FR-29  | A --dry-run flag shall run the full pipeline but suppress alert dispatch, logging what would have been sent.                     | **P1**       | Safe testing      |
| FR-30  | Config shall support multiple token pairs monitored simultaneously.                                                              | **P2**       | Multi-pair        |

## **4.6 Logging and observability**

| **ID** | **Requirement**                                                                                                                                | **Priority** | **Notes**          |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ------------------ |
| FR-31  | All log output shall be structured JSON, written to stdout, with fields: timestamp, level, component, message, and optional key-value context. | **P0**       | Machine-parseable  |
| FR-32  | Latency of each BBO fetch shall be logged at DEBUG level in microseconds.                                                                      | **P0**       | Latency visibility |
| FR-33  | The engine shall expose a /metrics HTTP endpoint (Prometheus text format) on a configurable port.                                              | **P1**       | Observability      |
| FR-34  | A /health HTTP endpoint shall return 200 if all fetchers have succeeded within the last 10 s, and 503 otherwise.                               | **P1**       | Health check       |
| FR-35  | On SIGINT or SIGTERM, the bot shall drain in-flight work, log a shutdown summary, and exit cleanly within 5 s.                                 | **P0**       | Graceful shutdown  |

# **5\. Non-functional requirements**

| **ID** | **Category**        | **Requirement**                                                    | **Target**              |
| ------ | ------------------- | ------------------------------------------------------------------ | ----------------------- |
| NFR-01 | **Latency**         | End-to-end time from BBO fetch start to alert dispatch (P99)       | < 500 ms                |
| NFR-02 | **Latency**         | Engine evaluation time per update cycle                            | < 1 ms                  |
| NFR-03 | **Throughput**      | BBO updates processable per second across all exchanges            | \> 1,000 / s            |
| NFR-04 | **Reliability**     | Bot uptime excluding planned maintenance                           | \> 99.5%                |
| NFR-05 | **Reliability**     | Maximum alert channel drop rate under normal load                  | 0%                      |
| NFR-06 | **Safety**          | Memory safety - no undefined behaviour, no use-after-free          | Zig compiler guaranteed |
| NFR-07 | **Safety**          | No hidden allocations - all allocators must be explicit and scoped | Zig allocator model     |
| NFR-08 | **Safety**          | No data races - all shared state must use explicit synchronisation | Verified by design      |
| NFR-09 | **Security**        | No credentials stored in source code or logs                       | Env var injection       |
| NFR-10 | **Maintainability** | Test coverage of engine and risk gate logic                        | \> 80%                  |
| NFR-11 | **Maintainability** | Adding a new exchange requires changes to one file only            | Gateway interface       |
| NFR-12 | **Portability**     | Builds on Linux (x86_64, aarch64) and macOS (arm64)                | Zig cross-compile       |
| NFR-13 | **Build**           | Clean build time on a 4-core machine (no cache)                    | < 60 s                  |

# **6\. System architecture**

## **6.1 Component overview**

The system is composed of five logical layers communicating through typed, bounded channels. No layer calls into the layer above it; all communication is downstream.

| **Fetcher layer**             | One thread per exchange. Each fetcher owns its HTTP client and pushes BboUpdate values into the BBO channel on every successful poll.                                |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **BBO channel**               | A bounded MPSC (multi-producer, single-consumer) ring buffer. Capacity is configurable (default 256). Back-pressure drops the oldest entry and logs a warning.       |
| **Arb engine**                | Single consumer of the BBO channel. Maintains exchange state table. Evaluates spreads and emits ArbOpportunity values to the risk gate.                              |
| **Risk gate**                 | Synchronous validation step in the engine thread. Reads risk metrics atomically. Passes or rejects each opportunity.                                                 |
| **Alert channel + notifiers** | Approved opportunities go into a bounded SPMC alert channel. One goroutine-equivalent thread per notifier (Slack, Discord) consumes from this channel independently. |

## **6.2 Project layout**

src/

main.zig - entry point, signal handling, thread spawning

config.zig - TOML parsing, validation, env-var override

channel.zig - generic bounded channel (MPSC and SPMC)

types.zig - BboUpdate, ArbOpportunity, RiskMetrics

engine.zig - ArbEngine: state table, spread evaluation

risk/

gate.zig - RiskGate, strategy composition

strategies.zig - MaxExposure, Drawdown, Volatility

gateway/

interface.zig - Gateway comptime interface

binance.zig - Binance REST fetcher

bybit.zig - ByBit REST fetcher

coinbase.zig - Coinbase REST fetcher

okx.zig - OKX REST fetcher

notify/

interface.zig - Notifier comptime interface

telegram.zig - Telegram notifier

http.zig - shared HTTP client wrapper (std.http)

log.zig - structured JSON logger

metrics.zig - Prometheus metrics server

build.zig - build definition

config.example.toml - annotated example configuration

## **6.3 Key data types**

The following types flow through the system. All fields are explicit; no nullable fields except where semantically required.

**BboUpdate** - emitted by each fetcher on every successful poll:

- exchange: Exchange - enum (Binance, ByBit, Coinbase, OKX)
- pair: TokenPair - e.g. { base: .BTC, quote: .USDC }
- bid: PriceLevel - { price: f64, size: f64 }
- ask: PriceLevel - { price: f64, size: f64 }
- fetched_at_us: i64 - monotonic microsecond timestamp

**ArbOpportunity** - emitted by the engine when a valid spread exists:

- buy_exchange / sell_exchange: Exchange
- pair: TokenPair
- profit_pct: f64 - (sell_bid - buy_ask) / buy_ask \* 100
- notional_usd: f64 - min(buy_ask_size, sell_bid_size) \* price, capped
- buy_bbo / sell_bbo: BBO
- detected_at_us: i64

# **7\. User experience narrative**

## **7.1 Normal operation - trader perspective**

The trader starts the bot with a single command, providing a config file path. Within 2 seconds the bot logs a startup summary showing each exchange's initial BBO fetch latency and the configured thresholds. The trader's Slack workspace sees no messages during normal market conditions.

When a spread opens - for example, BTC/USDC is offered at \$82,450 on Binance but bid at \$82,610 on ByBit - the engine detects this within one polling cycle. The spread is 0.19%, above the configured 0.1% threshold. The risk gate confirms exposure (\$12,400 notional) is within limits. A Slack message arrives within 400 ms of the fetchers returning data:

**🤖 Arbitrage opportunity detected** Pair: BTC/USDC Buy exchange: Binance ask \$82,450.00 Sell exchange: ByBit bid \$82,610.00 Profit: 0.1942% Notional: \$12,400.00 Detected at: 2026-03-24T14:32:07.411Z

The trader acts on the alert. The bot continues scanning and sends no duplicate alert for the same spread.

## **7.2 Risk rejection - risk officer perspective**

The risk officer has configured a maximum drawdown of 3%. During a volatile session, the portfolio's daily drawdown reaches 3.1%. The engine finds a 0.3% spread on ETH/USDC, but the risk gate rejects it. The structured log records:

{ "level": "INFO", "component": "risk_gate", "msg": "opportunity rejected", "reason": "DrawdownExceeded", "drawdown_pct": 3.1, "limit_pct": 3.0, "pair": "ETH/USDC" }

No alert fires. The risk officer sees the rejection in their log aggregator and is confident the gate is working correctly. No code change was required.

## **7.3 Exchange outage - operator perspective**

OKX's API returns HTTP 503 for 90 seconds. The OKX fetcher logs a WARN on each failed attempt, backs off, and retries. The /health endpoint returns 503 for OKX after 10 seconds, which the operator's monitoring system catches. The other three exchanges continue operating normally. When OKX recovers, the fetcher reconnects automatically and resumes without operator intervention.

# **8\. Milestones and sequencing**

**Team size estimate:** 1-2 engineers. **Total estimate:** 8 weeks to production-ready v1.0.

| **Phase**   | **Milestone**               | **Duration** | **Deliverables**                                                                                       |
| ----------- | --------------------------- | ------------ | ------------------------------------------------------------------------------------------------------ |
| **Phase 0** | Project foundation          | Week 1       | build.zig, config.zig, types.zig, channel.zig, log.zig, unit test harness                              |
| **Phase 1** | Gateway + HTTP layer        | Week 2       | http.zig, interface.zig, binance.zig, bybit.zig - BBO fetch verified against live API                  |
| **Phase 2** | Engine + remaining gateways | Week 3       | engine.zig, coinbase.zig, okx.zig - spread detection tested with mock data                             |
| **Phase 3** | Risk gate                   | Week 4       | gate.zig, strategies.zig - all three strategies, unit-tested with >80% coverage                        |
| **Phase 4** | Alert pipeline              | Week 5       | notify/interface.zig, slack.zig, discord.zig, alert channel - integration tested against real webhooks |
| **Phase 5** | Observability               | Week 6       | metrics.zig, /health endpoint, latency histograms, SIGHUP reload                                       |
| **Phase 6** | Hardening & integration     | Week 7       | End-to-end test with all 4 exchanges live, chaos testing (exchange kill), graceful shutdown            |
| **Phase 7** | Documentation & release     | Week 8       | README, config.example.toml, CHANGELOG, Docker image, v1.0 tag                                         |

WebSocket support (FR-06) is scoped to v1.1 and is not on the Phase 0-7 critical path.

# **9\. Success metrics**

## **9.1 User-centric**

- Alert latency P99 < 500 ms measured from fetch start to webhook POST completion.
- Zero false-positive alerts - every fired alert corresponds to a real spread at the moment of detection.
- Trader can read and understand each alert without consulting documentation.

## **9.2 Business**

- Bot uptime > 99.5% over any 30-day period.
- Risk gate rejection rate is logged and visible; zero silent bypasses.
- New exchange onboarding time < 4 hours of developer effort.

## **9.3 Technical**

- Engine evaluation latency < 1 ms per cycle (measured via log output).
- No memory leaks detected after 24-hour soak test (valgrind / zig build test -Dsanitize=address).
- Test coverage of engine.zig and risk/gate.zig > 80% (line coverage).
- Build time < 60 s on a 4-core machine from clean.

# **10\. Open questions**

| **Q-001** | Should the bot support multiple token pairs simultaneously in v1.0, or is single-pair sufficient for the initial release? (FR-30 is P2 - deferred by default.) |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Q-002** | What is the exact fee structure per exchange that should factor into the profit threshold? The current model compares raw prices without deducting taker fees. |
| **Q-003** | Should stale BBO data (fetched > N ms ago) be excluded from spread evaluation to prevent false positives on slow exchanges?                                    |
| **Q-004** | Is the notional cap (max trade amount) applied before or after the risk gate's exposure check? These should be equivalent but need confirmation.               |
| **Q-005** | Does the risk officer require a daily report digest (e.g. opportunities found, rejected, exchange uptime), or is the structured log sufficient?                |
| **Q-006** | Should the WebSocket gateway interface be designed now (even if not implemented) so the REST interface is compatible, or can it be retrofitted in v1.1?        |

# **11\. Risks and mitigations**

| **API rate limits**           | Exchanges impose per-IP rate limits. Mitigation: exponential back-off with jitter in each fetcher; configurable poll interval per exchange.                                                       |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Stale BBO data**            | A slow exchange may return outdated prices, generating false spreads. Mitigation: each BboUpdate carries a fetch timestamp; engine rejects entries older than a configurable staleness threshold. |
| **Exchange downtime**         | One or more exchanges may be unavailable for extended periods. Mitigation: fetcher isolation on dedicated threads, /health endpoint, automatic reconnection.                                      |
| **Zig std library stability** | Zig's std.http API changed significantly between 0.12 and 0.13. Mitigation: pin to Zig 0.13 stable; document upgrade procedure.                                                                   |
| **Channel back-pressure**     | High-frequency markets may overflow the BBO channel. Mitigation: drop-oldest strategy with WARNING log; configurable channel capacity.                                                            |
| **Clock skew**                | System clock adjustments can corrupt latency measurements. Mitigation: use std.time.Timer (monotonic) for all latency measurements; wall clock only for log timestamps.                           |

# **12\. Requirements traceability matrix**

Every functional requirement maps to at least one user story. Every user story has testable acceptance criteria.

| **FR / NFR**               | **User story** | **Acceptance criteria**                    |
| -------------------------- | -------------- | ------------------------------------------ |
| FR-01, FR-02, FR-03        | US-001         | AC-01, AC-02, AC-03                        |
| FR-04                      | US-002         | AC-01, AC-02                               |
| FR-05                      | US-001, US-003 | AC-04                                      |
| FR-06                      | US-010         | AC-01, AC-02                               |
| FR-07                      | US-011         | AC-01                                      |
| FR-08, FR-09, FR-10, FR-11 | US-003         | AC-01, AC-02, AC-03, AC-04                 |
| FR-12                      | US-003, US-004 | AC-05                                      |
| FR-13                      | US-003         | AC-06                                      |
| FR-14, FR-15, FR-16        | US-005         | AC-01, AC-02, AC-03                        |
| FR-17                      | US-005         | AC-04                                      |
| FR-18, FR-19               | US-006         | AC-01, AC-02                               |
| FR-20                      | US-012         | AC-01                                      |
| FR-21, FR-22               | US-004         | AC-01, AC-02, AC-03                        |
| FR-23                      | US-004         | AC-04                                      |
| FR-24                      | US-007         | AC-01, AC-02                               |
| FR-25                      | US-011         | AC-02                                      |
| FR-26, FR-27, FR-28        | US-008         | AC-01, AC-02, AC-03                        |
| FR-29                      | US-008         | AC-04                                      |
| FR-31, FR-32               | US-009         | AC-01, AC-02                               |
| FR-33, FR-34               | US-009         | AC-03, AC-04                               |
| FR-35                      | US-007         | AC-03                                      |
| NFR-01-NFR-03              | US-001, US-003 | Latency and throughput acceptance criteria |
| NFR-06-NFR-08              | US-013         | AC-01, AC-02, AC-03                        |

# **13\. User stories**

All user stories are written against the personas defined in section 3. Acceptance criteria (AC) are numbered within each story and are the definitive test conditions for that story.

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-001 Parallel BBO fetching from all exchanges P0</strong></p></th></tr><tr><td><p><strong>As a </strong>quantitative trader,</p><p><strong>I want to </strong>have BBO data fetched from all configured exchanges simultaneously,</p><p><strong>so that </strong>the total polling latency is bounded by the slowest single exchange, not their sum.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given 4 exchanges are configured, when the scanner starts a cycle, all 4 HTTP requests are dispatched within 10 ms of each other.</li><li><strong>AC-02: </strong>Given all 4 exchanges respond within 400 ms, the engine receives all 4 BboUpdate values before 500 ms has elapsed from cycle start.</li><li><strong>AC-03: </strong>Given one exchange times out at 500 ms, the other 3 BboUpdate values are available to the engine before the timeout elapses.</li><li><strong>AC-04: </strong>Each BboUpdate carries exchange, pair, bid.price, bid.size, ask.price, ask.size, and fetched_at_us.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-002 Resilient fetcher with back-off on error P0</strong></p></th></tr><tr><td><p><strong>As a </strong>quantitative trader,</p><p><strong>I want to </strong>the bot to automatically recover from exchange API errors,</p><p><strong>so that </strong>I do not need to restart the bot when an exchange has a transient issue.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given an exchange returns HTTP 5xx, the fetcher logs a WARN with the status code and does not crash.</li><li><strong>AC-02: </strong>Given the same exchange continues to fail, the fetcher retries after a back-off starting at 1 s, capped at 30 s.</li><li><strong>AC-03: </strong>Given the exchange recovers, the fetcher resumes normal polling on the next successful response without operator action.</li><li><strong>AC-04: </strong>Given 10 consecutive failures from one exchange, the other exchanges continue fetching unaffected.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-003 Best-spread detection per evaluation cycle P0</strong></p></th></tr><tr><td><p><strong>As a </strong>quantitative trader,</p><p><strong>I want to </strong>the engine to identify the single best arbitrage opportunity across all exchange pairs per cycle,</p><p><strong>so that </strong>I receive alerts only for the most profitable spread, avoiding duplicate or suboptimal alerts.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given exchange A has ask $100 and exchange B has bid $101, the engine emits an ArbOpportunity with profit_pct = 1.0%.</li><li><strong>AC-02: </strong>Given two valid spreads exist in the same cycle (0.5% and 0.8%), only the 0.8% opportunity is emitted.</li><li><strong>AC-03: </strong>Given sell_bid &lt;= buy_ask on all pairs, no ArbOpportunity is emitted.</li><li><strong>AC-04: </strong>Given profit_pct &lt; min_profit config, no ArbOpportunity is emitted even if sell_bid &gt; buy_ask.</li><li><strong>AC-05: </strong>The ArbOpportunity includes: buy_exchange, sell_exchange, pair, profit_pct, notional_usd, buy_bbo, sell_bbo, detected_at_us.</li><li><strong>AC-06: </strong>Engine evaluation completes in &lt; 1 ms for up to 6 exchanges (15 pairs).</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-004 Timely Slack and Discord alerts P0</strong></p></th></tr><tr><td><p><strong>As a </strong>quantitative trader,</p><p><strong>I want to </strong>receive a Slack and/or Discord message when a valid, risk-approved opportunity is detected,</p><p><strong>so that </strong>I can act on the information within seconds of the spread opening.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given a risk-approved ArbOpportunity, a Slack POST is made within 500 ms of detected_at_us.</li><li><strong>AC-02: </strong>The Slack message contains: pair, buy exchange, sell exchange, profit_pct (4 decimal places), notional_usd (2 decimal places), buy price, sell price, detected_at timestamp.</li><li><strong>AC-03: </strong>Given the Slack webhook returns 200, no retry is attempted.</li><li><strong>AC-04: </strong>Given Discord is also configured, the same opportunity is posted to Discord independently of Slack.</li><li><strong>AC-05: </strong>Given both notifiers are configured, a failure on one does not suppress the other.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-005 Mandatory risk gate enforcement P0</strong></p></th></tr><tr><td><p><strong>As a </strong>risk officer,</p><p><strong>I want to </strong>be certain that no alert is dispatched unless all configured risk checks pass,</p><p><strong>so that </strong>I can trust that the bot operates within the risk parameters I have set without inspecting code.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given notional_usd &gt; max_exposure_per_trade config, the opportunity is rejected and logged; no alert fires.</li><li><strong>AC-02: </strong>Given portfolio drawdown &gt; max_drawdown_pct config, the opportunity is rejected and logged; no alert fires.</li><li><strong>AC-03: </strong>Given volatility &gt; max_volatility config (when configured), the opportunity is rejected and logged; no alert fires.</li><li><strong>AC-04: </strong>Given all checks pass, the opportunity proceeds to the alert channel.</li><li><strong>AC-05: </strong>The rejection log entry includes: reason, the failing metric value, the configured limit, pair, and timestamp.</li><li><strong>AC-06: </strong>There is no code path that emits an alert without passing through the risk gate.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-006 Risk metrics updated on a background thread P0</strong></p></th></tr><tr><td><p><strong>As a </strong>risk officer,</p><p><strong>I want to </strong>have risk metrics (drawdown, exposure, volatility) refreshed automatically on a regular interval,</p><p><strong>so that </strong>the risk gate reflects current portfolio state without any manual action.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Risk metrics are updated every N seconds as configured (default 5 s).</li><li><strong>AC-02: </strong>Risk metric updates do not block the engine thread or delay spread evaluation.</li><li><strong>AC-03: </strong>If the risk metrics update fails, the previous metric values are retained and a WARN is logged.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-007 Graceful shutdown and notifier resilience P0</strong></p></th></tr><tr><td><p><strong>As a </strong>developer / operator,</p><p><strong>I want to </strong>the bot to shut down cleanly and for notifier failures not to crash the system,</p><p><strong>so that </strong>I can stop the bot safely and production stability is maintained under notification failures.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given SIGINT or SIGTERM, the bot stops accepting new work, drains in-flight opportunities, and exits within 5 s.</li><li><strong>AC-02: </strong>Given a Slack POST returns non-200, the notifier retries once after 2 s, logs an ERROR if the retry fails, and continues running.</li><li><strong>AC-03: </strong>On shutdown, a summary log is emitted with total opportunities detected, passed risk gate, and alerts sent.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-008 Config-driven startup with validation P1</strong></p></th></tr><tr><td><p><strong>As a </strong>developer / operator,</p><p><strong>I want to </strong>configure all bot parameters via a TOML file and environment variables without recompiling,</p><p><strong>so that </strong>I can deploy the same binary to different environments with different settings.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>The bot loads config from the path specified by --config flag (default: config.toml).</li><li><strong>AC-02: </strong>Environment variables for webhook URLs and any secret field override config file values.</li><li><strong>AC-03: </strong>Given a required field is missing, the bot exits with exit code 1 and prints the missing field name.</li><li><strong>AC-04: </strong>Given --dry-run flag, the bot runs the full pipeline but logs 'DRY RUN - alert suppressed' instead of posting to webhooks.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-009 Structured logs and observability endpoints P1</strong></p></th></tr><tr><td><p><strong>As a </strong>developer / operator,</p><p><strong>I want to </strong>have structured JSON logs and Prometheus metrics available from the running bot,</p><p><strong>so that </strong>I can integrate the bot into existing monitoring infrastructure without custom parsing.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Every log line is valid JSON with fields: timestamp (ISO 8601), level, component, msg.</li><li><strong>AC-02: </strong>Each BBO fetch latency is logged at DEBUG level with field fetch_latency_us.</li><li><strong>AC-03: </strong>GET /metrics returns a valid Prometheus text format response with at least: arb_opportunities_total, arb_alerts_sent_total, arb_risk_rejected_total, bbo_fetch_latency_us (histogram).</li><li><strong>AC-04: </strong>GET /health returns HTTP 200 if all fetchers succeeded within the last 10 s, 503 otherwise.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-010 WebSocket price feed support (v1.1) P1</strong></p></th></tr><tr><td><p><strong>As a </strong>quantitative trader,</p><p><strong>I want to </strong>configure individual exchanges to receive prices via WebSocket instead of REST polling,</p><p><strong>so that </strong>the latency from price change to engine update is reduced from poll-interval to near-zero.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given an exchange is configured with feed: websocket, the fetcher establishes a persistent WebSocket connection.</li><li><strong>AC-02: </strong>Each incoming ticker message updates the BBO channel within 5 ms of receipt.</li><li><strong>AC-03: </strong>Given the WebSocket disconnects, the fetcher falls back to REST polling and logs a WARN until reconnected.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-011 Adding a new exchange without modifying existing files P1</strong></p></th></tr><tr><td><p><strong>As a </strong>developer / operator,</p><p><strong>I want to </strong>implement a new exchange gateway by creating a single new file that satisfies the Gateway interface,</p><p><strong>so that </strong>the codebase remains modular and adding an exchange does not risk breaking existing gateways.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>A new exchange can be added by creating src/gateway/newexchange.zig and registering it in config.zig (one line).</li><li><strong>AC-02: </strong>No existing gateway file is modified when adding the new exchange.</li><li><strong>AC-03: </strong>The new gateway is automatically included in the engine's fetcher pool when configured.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-012 Hot-reloadable risk configuration P1</strong></p></th></tr><tr><td><p><strong>As a </strong>risk officer,</p><p><strong>I want to </strong>update risk thresholds at runtime by sending SIGHUP without restarting the bot,</p><p><strong>so that </strong>I can tighten or relax risk limits in response to market conditions without downtime.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Given the risk config file is updated and SIGHUP is sent, the bot reloads risk parameters within 1 s.</li><li><strong>AC-02: </strong>Given the updated config file contains an invalid value, the reload is rejected, the previous config is retained, and an ERROR is logged.</li><li><strong>AC-03: </strong>The reload event is logged with the old and new values for each changed parameter.</li></ol></td></tr></tbody></table></div>

<div class="joplin-table-wrapper"><table><tbody><tr><th><p><strong>US-013 Memory safety and no data races P0</strong></p></th></tr><tr><td><p><strong>As a </strong>developer / operator,</p><p><strong>I want to </strong>run the bot under Zig's address sanitizer and thread sanitizer without errors,</p><p><strong>so that </strong>I have confidence in production stability and can reason about all shared state explicitly.</p><p><strong>Acceptance criteria:</strong></p><ol><li><strong>AC-01: </strong>Running zig build test -Dsanitize=address reports zero memory errors across all unit and integration tests.</li><li><strong>AC-02: </strong>All shared state between threads is protected by explicit mutex or atomic access - there are no unprotected concurrent writes.</li><li><strong>AC-03: </strong>All heap allocations use an explicit, scoped allocator; there are no global allocators or hidden allocations.</li></ol></td></tr></tbody></table></div>
