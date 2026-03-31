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

## EC2 Deployment (systemd)

### Prerequisites

- EC2 instance (Ubuntu 22.04+ recommended)
- SSH access with sudo privileges

### First-time setup

```sh
# Clone to /opt/cex-zig
sudo git clone https://github.com/owenstack/crypto-earn.git /opt/cex-zig
cd /opt/cex-zig

# Provision: installs deps, creates cex-engine user, installs systemd units
sudo scripts/provision.sh

# Configure environment
sudo cp .env.example .env
sudo nano .env  # Set real values
sudo chown cex-engine:cex-engine .env
sudo chmod 0640 .env
```

### Deploy

```sh
scripts/deploy.sh --restart-services
```

### Verify

```sh
scripts/verify.sh
```

## Operational Commands

```sh
# Start / stop / restart services
sudo systemctl start cex-engine cex-control
sudo systemctl stop cex-engine cex-control
sudo systemctl restart cex-engine cex-control

# Status
sudo systemctl status cex-engine cex-control

# Logs (follow)
sudo journalctl -u cex-engine -f
sudo journalctl -u cex-control -f

# Run database migrations (DB_PATH is required)
# Option 1: pass DB_PATH as a CLI argument
scripts/migrate.sh /opt/cex-zig/zig/data/cex.db

# Option 2: export DB_PATH in the environment
export DB_PATH=/opt/cex-zig/zig/data/cex.db
scripts/migrate.sh

# Post-deploy validation (end-to-end)
scripts/e2e-test.sh

# Latency profiling
scripts/latency-profile.sh
```

## Rollback

1. Stop services: `sudo systemctl stop cex-engine cex-control`
2. Checkout previous tag/commit: `git checkout <previous-tag>`
3. Rebuild: `cd zig && zig build -Doptimize=ReleaseFast`
4. Restart: `sudo systemctl start cex-engine cex-control`

> **Note:** Migration rollback is not automated. SQLite — restore from backup if needed.

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

- Native WebSocket upgrade support is not yet implemented in the Zig client.
- Current runtime behavior uses REST polling fallback for market updates.

Supported types (Phase 0): `heartbeat`, `status`, `portfolio`, `orders`, `config.get`, `logs`.

## Verification

Run the unified verification script to check the build, typecheck, tests, and service health:

```sh
scripts/verify.sh
```
