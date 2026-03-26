# cex-zig — CEX Trading Engine

Low-latency crypto trading engine with a Zig core and a TypeScript control plane.

## Architecture

```
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
| 1 | Strategy signals, risk gate, order execution (CLOB signing) |
| 2 | Multi-exchange, advanced risk, backtesting |

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

Optional/common keys:

- `DASHBOARD_PORT` (default: `3000`)
- `LOG_LEVEL` (example: `info`)
- `NODE_ENV` (example: `development`)

## Quick Start (local)

```sh
cp .env.example .env
# Edit .env with real values

# Terminal 1 – Zig engine
cd zig && zig build run

# Terminal 2 – TS control plane
cd ts && bun run dev
```

## IPC Protocol

JSON-lines over UNIX domain socket (`IPC_SOCKET`).

Envelope:
```json
{ "v": 1, "id": "<uuid>", "ts": <epoch_ms>, "type": "<type>", "payload": {} }
```

Supported types (Phase 0): `heartbeat`, `status`, `portfolio`, `orders`, `config.get`, `logs`.

## Verification

```sh
# 1. Zig build
cd zig && zig build -Doptimize=ReleaseFast

# 2. TS typecheck
cd ts && bun run typecheck

# 3. Contract tests
cd ts && bun test src/ipc/
```
