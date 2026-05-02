# Debug Summary

## Problem

There are two separate issues:

1. False risk rejection:
`MaxPortfolioExposureExceeded` was being triggered even with no real open orders because stale local `pending` orders were still counted as exposure/open capacity after restarts.

2. Restart/offline issue:
the bot is not merely "going offline"; the `engine` process is crashing with a segfault and Docker is restarting it. The `control` service only appears offline because its IPC socket disconnects every time `engine` dies.

The dry-run result is important: long-running dry run is stable, which strongly suggests the crash is in a live-trading path, not the general market feed / scanner / dry-run loop.

## Changes Made

The false risk rejection and balance fallback were fixed:

- In `zig/src/db.zig`, open-order count and exposure now only include `placed` and `partially_filled`, not stale `pending`.
- In `zig/src/fill_poller.zig`, startup reconciliation now sweeps stale `pending` rows into `rejected`.
- In `zig/src/main.zig`, USDC balance fetch now retries using the signer address if the primary balance address fails.
- `zig build` passed after those fixes.

The Zig engine was then instrumented for the segfault:

- Added `zig/src/crash_trace.zig`, which installs signal handlers for fatal crashes and dumps the last in-memory breadcrumbs.
- Wired breadcrumbs into:
  - startup in `zig/src/main.zig`
  - websocket/orderbook persistence in `zig/src/main.zig`
  - strategy dispatch in `zig/src/main.zig`
  - live order submission in `zig/src/order_manager.zig`
- Added a selectable Docker build mode:
  - `Dockerfile.engine`
  - `docker-compose.yml`
- The engine image can now be built in debug mode with:

```bash
ENGINE_OPTIMIZE=Debug docker compose up --build
```

## Confirmed Findings

From Docker/event/log inspection:

- `engine` was repeatedly dying with `exitCode=139`.
- The restart cadence was about every 13-14 seconds.
- `control` disconnect/reconnect timing matched those crashes exactly.
- Stopping `control` entirely did not stop the engine crashes, so IPC subscription is not the root cause.
- Temporary one-off engine containers created during isolation caused real SQLite lock noise and were later removed. They were not the root segfault cause.

From live logs, there are also ongoing runtime issues:

- reconciliation call to `GET /orders?...status=open` returns `405`
- primary `balance-allowance` returns `401`
- CLOB submissions often return `order_version_mismatch`
- `ws_feed` logs heavy `"<overflow>"`
- SQLite periodically reports lock/checkpoint problems

These are real problems, but the critical one is still the segfault.

From isolation runs:

- engine-only with both strategies disabled: no segfault within the observation window
- engine-only LP-only: no segfault within the observation window
- engine-only news-only: no segfault within the observation window

This suggests the crash likely depends on sustained live runtime / concurrency and not just a simple deterministic startup path.

## Current State

The last restart attempt was interrupted.

Current Compose state at the end of this summary:

- `docker compose ps` showed no running services

So the stack is currently down.

## Next Steps

1. Bring the stack back up with the new instrumentation rebuilt into the image:

```bash
ENGINE_OPTIMIZE=Debug docker compose up --build
```

2. Let it crash at least once and inspect the engine logs for the breadcrumb dump emitted by `crash_trace.zig`.

3. Use those final breadcrumb lines to identify whether the segfault is happening in:
- websocket persistence path
- live order signing/body construction
- HTTP submission path
- DB status transition after submit

4. Patch the specific crashing path once identified.

The key conclusion is that this is not a generic dry-run/feed stability issue, and it is not just the dashboard going offline. It is a live-path engine segfault under real trading conditions.
