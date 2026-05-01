# cex-zig — CEX Trading Engine

Low-latency crypto trading engine with a Zig core and a TypeScript control plane.

## Architecture

```sh
zig/   — Trading engine (SQLite WAL, UNIX IPC server)
ts/    — Control plane (Telegram bot + Web dashboard)
db/    — Schema & migrations
scripts/   — Provisioning and orchestration
systemd/   — Service units
infrastructure/ — Terraform (Phase 2+)
```

## Phase Map

| Phase | Scope |
|-------|-------|
| **0** | Infrastructure, split architecture, SQLite WAL, IPC transport, read-only control plane |
| **1** | Strategy signals, risk gate, order execution (CLOB signing) |
| **2** | Multi-exchange, advanced risk, backtesting |
| **3** | Paper-trading simulation, P&L tracking |
| **4** | Live execution hardening, circuit breakers |
| **5** | Observability, metrics, alerting |
| **6** | Performance tuning, latency profiling |
| **7** | Deployment automation, systemd hardening, e2e validation |

## Prerequisites

Install these tools before running the local stack:

- Zig 0.15.2+ (recommended: 0.15.2 to match project toolchain)
- Bun 1.1+ (used for TS runtime, scripts, and tests)
- SQLite 3.35+ (used by Zig engine with WAL mode)

Quick checks:

```sh
zig version
bun --version
sqlite3 --version
```

## Environment Variables

Before starting services, copy the template and set required values:

```sh
cp .env.example .env
```

Required keys in `.env`:

- `IPC_SOCKET`: UNIX socket path shared by Zig and TS.
  - Example: `/tmp/cex-engine.sock`
- `DB_PATH`: SQLite database file path used by the engine.
  - Example: `./data/cex.db`
- `TELEGRAM_BOT_TOKEN`: Telegram bot token from BotFather.
  - Get it from Telegram `@BotFather` after creating a bot.
  - Example: `123456789:AAExampleTokenValue`
- `TELEGRAM_ALLOWED_CHAT_IDS`: Comma-separated chat IDs allowed to use the bot.
  - You can get your chat ID from bots like `@userinfobot`.
  - Example: `123456789,987654321`
- `DASHBOARD_SECRET`: Bearer token used to protect dashboard API routes.
  - Generate with: `openssl rand -hex 32`
  - Example: `d43b6fd9a0a81b7e5f6be4a6bd3d2f0e9f0c0ad4c08371d4d4f3d4a2df922e15`
- `POLYMARKET_PRIVATE_KEY`: Polymarket wallet private key used by the engine for live order signing.

Optional/common keys:

- `KALSHI_API_KEY` (strongly recommended for primary probability data)
- `DASHBOARD_PORT` (default: `3000`)
- `LOG_LEVEL` (example: `info`)
- `NODE_ENV` (example: `production`)
- `DRY_RUN_INITIAL_BALANCE` (default: `10.0`)

Optional overrides:

- `kalshi_market_map`: legacy runtime config override for manually pinning Kalshi tickers to Gamma IDs when auto-discovery is wrong.

## Quick Start (Docker — recommended)

```sh
cp .env.example .env
# Edit .env with real values (TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_CHAT_IDS, etc.)

# Build and start both services
docker compose up -d --build

# View logs
docker compose logs -f

# Stop
docker compose down
```

The Zig engine runs migrations automatically on startup. Data is persisted in a Docker volume (`engine-data`).

## Quick Start (local, no Docker)

```sh
cp .env.example .env
# Edit .env with real values

# Terminal 1 – Zig engine
cd zig && zig build run

# Terminal 2 – TS control plane
cd ts && bun run dev
```

## Operational Commands (Docker)

```sh
# Start / stop / restart
docker compose up -d
docker compose down
docker compose restart

# Logs (follow)
docker compose logs -f engine
docker compose logs -f control

# Rebuild after code changes
docker compose up -d --build

# Shell into a running container
docker compose exec engine sh
docker compose exec control bash
```

## Rollback

1. Stop services: `docker compose down`
2. Checkout previous tag/commit: `git checkout <previous-tag>`
3. Rebuild and start: `docker compose up -d --build`

> **Note:** Migration rollback is not automated. Back up the `engine-data` volume if needed.

## Security Model

- **Dashboard is read-only** — no write or trade endpoints are exposed.
- **Telegram is the control surface** — place orders, halt/resume, strategy control all go through the Telegram bot.
- **Unprivileged execution** — services run as the `cex-engine` user with systemd sandboxing (`ProtectSystem`, `PrivateTmp`, `NoNewPrivileges`, etc.).
- **Firewall** — recommended: allow only SSH + dashboard port; block all other inbound traffic.
- **Dashboard auth** — restrict access with `DASHBOARD_SECRET` Bearer token authentication.
- **`.env` permissions** — file should be owned by `cex-engine:cex-engine` with mode `0640`.

## IPC Protocol

JSON-lines over UNIX domain socket (`IPC_SOCKET`).

Envelope:

```json
{ "v": 1, "id": "<uuid>", "ts": <epoch_ms>, "type": "<type>", "payload": {} }
```

## Market Data Transport

Real-time CLOB price feeds are delivered via WebSocket to
`ws-subscriptions-clob.polymarket.com`. Token IDs are subscribed dynamically
as markets are discovered by the scanner. New markets are subscribed without
reconnecting via dynamic subscription messages on the live socket.

Supported types (Phase 0): `heartbeat`, `status`, `portfolio`, `orders`, `config.get`, `logs`.

## Kalshi Integration

The engine automatically maps Kalshi tickers to Polymarket markets using a
three-tier resolution strategy:

1. DB-persisted map: previously discovered mappings that survive restarts.
2. Runtime auto-map: mappings discovered during the current session.
3. Title fuzzy-match: normalized matching against market questions in SQLite.

No manual configuration is required. Discovered mappings are written to the
`kalshi_market_map` table and can be inspected with `/mappings` in Telegram.
The optional `kalshi_market_map` runtime config key still works as a manual
override for edge cases.

## Runtime Tuning

All values below can be changed live with `/config set <key> <value>`.

| Key | Default | Description |
|-----|---------|-------------|
| `lp_cooldown_seconds` | 15 | Seconds between LP signals per market |
| `lp_max_position_usd_pct` | 0.20 | LP max exposure as fraction of balance |
| `max_order_size_usd` | unset | Hard cap on any single order |
| `prob_source_poll_seconds` | 60 | Kalshi REST poll interval |
| `kalshi_series_tickers` | unset | Comma-separated Kalshi series to focus on |
| `kalshi_api_key` | unset | Required for Kalshi WS primary source |

## Dry-Run Mode

Set `DRY_RUN=1` in `.env` to run without placing real orders.

In dry-run mode the engine generates real signals against live market data,
simulates fills from live bid/ask prices, tracks order lifecycle in
`dry_run_orders`, updates a virtual USDC balance in `balance_snapshots`, and
applies the same risk gate against that virtual balance. Use `/drystatus` in
Telegram for the go/no-go summary before live deployment.

## Verification

Run the unified verification script to check the build, typecheck, tests, and service health:

```sh
scripts/verify.sh
```
