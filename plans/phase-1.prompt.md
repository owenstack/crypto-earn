# Plan: Phase 1 — Zig Core: Market Data & Client

## TL;DR

Phase 1 implements the three core Zig components needed for low-latency market data and order placement:
1. **HTTP client** (Gamma API + CLOB REST) using native Zig http.Client
2. **WebSocket client** (CLOB price feed) with auto-reconnect, exponential backoff, and subscription management  
3. **Cryptography module** (EIP-712 signing) using libsecp256k1 via C FFI
4. **Market scanner** that polls Gamma API, filters by liquidity/volume/time-to-resolution, and maintains an in-memory market registry
5. **Order book tracker** that subscribes to CLOB WebSocket and persists snapshots to SQLite

Upon completion, Phase 1 enables:
- The strategy engine (Phase 3) to consume market data
- The order manager (Phase 2) to construct signed EIP-712 order messages
- Real-time price feeds with < 500ms latency (AC-04) and WebSocket reconnection within 30s (AC-05)

---

## Steps

### **Step 1: Set up C FFI and link libsecp256k1** (*depends on Phase 0 build.zig*)
1. Modify `zig/build.zig` to link `libsecp256k1` alongside existing `sqlite3` linkage.
2. Create `zig/src/crypto.zig` — Zig wrapper around libsecp256k1 C API:
   - Define C function signatures for `keccak256`, `secp256k1_context_create/destroy`, `secp256k1_ecdsa_sign`, `secp256k1_ec_pubkey_serialize`.
   - Implement high-level Zig functions: `hash_keccak256(data: []const u8) [32]u8`, `sign_eip712(digest: [32]u8, private_key: [32]u8) Signature struct`.
   - Store raw signature bytes (r, s, v) in a `Signature` type compatible with EVM smart contracts.

### **Step 2: Implement HTTP client module**
1. Create `zig/src/http_client.zig` wrapping Zig's builtin `std.http.Client`:
   - Define request/response builders for GET and POST.
   - Implement methods: `get()`, `post()`, `post_json()`.
   - Include user-agent header, Content-Type, and connection pool reuse.
   - Add error handling for 4xx/5xx and network timeouts.
   - **No external dependencies** — use native Zig http.Client.

### **Step 3: Implement WebSocket client module** (*can parallel with Step 2*)
1. Create `zig/src/websocket.zig` for WebSocket upgrade and frame handling:
   - Handshake: HTTP Upgrade request, header parsing (Sec-WebSocket-Accept verification).
   - Frame parsing: Read opcode, payload length, masking, data.
   - Auto-reconnect with exponential backoff (250ms → 30s max) on disconnect.
   - Subscription management: Track active subscriptions by market_id; replay subscriptions on reconnect.
   - Connection pooling: Single long-lived WebSocket connection per server (CLOB endpoint).
   - Received frames routed to a callback (price update handler).

### **Step 4: Create Gamma API poller module**
1. Create `zig/src/gamma_api.zig`:
   - Define `GammaMarket` struct matching Gamma API response schema (market_id, base_token, quote_token, 24h_volume, liquidity, etc.).
   - Implement `poll_markets()` function that:
     - Calls `GET https://gamma-api.polymarket.com/markets` (with configurable pagination).
     - Filters results by: `volume_24h >= min_volume`, `total_liquidity >= min_liquidity`, `resolved_at - now < max_resolution_days`, optional category.
     - Returns filtered `[]GammaMarket`.
   - Add configuration struct for filter thresholds (default: volume=$5000, liquidity=$1000, resolution=30 days).

### **Step 5: Implement CLOB order book tracker**
1. Create `zig/src/clob_orderbook.zig`:
   - Define `OrderBook` struct: `market_id`, `best_bid`, `best_ask`, `mid_price`, `timestamp`, depth snapshots.
   - Implement `fetch_orderbook(market_id)` → queries `GET https://clob.polymarket.com/books/{market_id}`.
   - Store orderbook snapshots in SQLite `orderbooks` table (struct contains JSON serialization).

### **Step 6: Extend IPC messages for market data** (*depends on Step 1–5*)
1. Update `zig/src/ipc_types.zig`:
   - Add message types: `market.list`, `orderbook.snapshot`, `price.update`.
   - Define payload types: `MarketListPayload` ([]Market), `OrderbookPayload` (BBO + depth), `PriceUpdatePayload` (market_id, new_bid, new_ask, mid, timestamp).

### **Step 7: Build market scanner main loop**
1. Create `zig/src/market_scanner.zig`:
   - Maintain in-memory `Market[]` registry with last-polled timestamp.
   - Timer loop: every N minutes (config-driven, default 10):
     - Call `gamma_api.poll_markets()`.
     - Compare to current registry; log additions/removals.
     - Persist market list to SQLite `markets` table.
   - WebSocket subscription loop (in parallel thread via std.Thread):
     - For each market in registry, ensure CLOB WebSocket subscription to `{market_id}`.
     - Receive `price.update` frames; parse and route to order book tracker.
     - Log subscription failures; attempt reconnect.

### **Step 8: Integrate scanner into main.zig** (*depends on Step 7*)
1. Update main.zig:
   - Spawn market scanner thread immediately after DB init.
   - Pass allocator, database handle, and config to scanner.
   - Ensure graceful shutdown: cancel scanner loop on SIGINT.

### **Step 9: Write unit tests and integration tests**
1. Create tests in `zig/src/tests.zig`:
   - **Unit tests:**
     - `crypto.zig`: Sign a test message, verify signature structure.
     - `http_client.zig`: Mock GET/POST requests; validate parsing.
     - `gamma_api.zig`: Mock Gamma API response; verify filtering logic.
     - `clob_orderbook.zig`: Parse mock order book JSON; verify BBO extraction.
   - **Integration tests (require network or mocks):**
     - Market scanner loop: poll Gamma API once, verify market count > 0.
     - WebSocket: connect to test WebSocket, receive one price update, verify parsing.
     - IPC: scanner sends `market.list` message; verify TS client receives it correctly.

### **Step 10: Update build script and documentation**
1. Verify `zig build` compiles all new modules; test with `zig build test`.
2. Update `zig/README.md` or main `README.md`:
   - Document HTTP client usage (timeouts, retries).
   - Document WebSocket reconnection behavior.
   - Document EIP-712 signing API.
   - List external C dependencies (libsecp256k1, sqlite3).

---

## Relevant Files

**To Create:**
- `zig/src/crypto.zig` — libsecp256k1 wrapper, EIP-712 signing
- `zig/src/http_client.zig` — HTTP client, request/response builders
- `zig/src/websocket.zig` — WebSocket frame handling, auto-reconnect
- `zig/src/gamma_api.zig` — Gamma API poller, market filtering
- `zig/src/clob_orderbook.zig` — Order book fetch and storage
- `zig/src/market_scanner.zig` — Main market discovery loop
- `zig/src/tests.zig` — Unit and integration tests (extend existing)

**To Modify:**
- `zig/build.zig` — Add libsecp256k1 linkage
- `zig/src/ipc_types.zig` — Add market.list, orderbook.snapshot, price.update messages
- `zig/src/main.zig` — Spawn market scanner thread
- `zig/src/db.zig` — Add tables for market snapshots, order book history (if not already present)
- `ts/src/ipc/types.ts` — Mirror new IPC message types for TS side

**Reference:**
- [CLOB API docs](https://docs.polymarket.com) — order book endpoint, WebSocket feed format
- [Gamma API docs](https://docs.polymarket.com) — market list, filtering parameters
- [EIP-712 spec](https://eips.ethereum.org/EIPS/eip-712) — domain separator, struct hash

---

## Verification

1. **Unit tests pass:**
   - `zig build test` — all crypto, HTTP, WebSocket, Gamma API tests succeed.

2. **Market list accuracy:**
   - Gamma API poller returns ≥ 50 markets after first poll.
   - Filtering removes markets with `volume_24h < $5000` and `liquidity < $1000`.

3. **Order book fetch:**
   - CLOB order book endpoint responds with BBO; parser extracts bid/ask/mid correctly.

4. **WebSocket connectivity (local mock or real endpoint):**
   - Subscribe to ≥ 5 markets.
   - Receive price update frame within 500 ms of a market price change.
   - On disconnect, reconnect within 30 s with exponential backoff.

5. **IPC messaging:**
   - Market scanner sends `market.list` via IPC every 10 minutes.
   - TS client receives and parses message correctly.
   - TS Dashboard/Telegram bot can display live market list.

6. **Database persistence:**
   - Market snapshots written to SQLite every poll cycle.
   - Order book snapshots persisted on each WebSocket price update.
   - Historical queries work correctly (SELECT * FROM markets ORDER BY created_at DESC).

7. **Performance baselines (NFR):**
   - Log timestamp from WebSocket frame receipt to order book update in SQLite: verify < 10 ms latency.

---

## Decisions

- **Crypto choice:** libsecp256k1 via C FFI (battle-tested, audited, faster than pure Zig alternatives).
- **HTTP choice:** Native Zig http.Client (zero external dependencies, sufficient for REST APIs).
- **WebSocket choice:** Custom frame parser in Zig (full control, low-latency processing).
- **Market filtering:** Applied client-side after Gamma API fetch (allows easy config changes without re-polling).
- **Registry storage:** In-memory during runtime; persisted to SQLite for audit/recovery.
- **Thread model:** Market scanner and WebSocket listener run in separate std.Thread to avoid blocking IPC main loop.

---

## Further Considerations

1. **libsecp256k1 availability on CI/deployment machines?**
   - Recommendation: Document build prerequisites in README (e.g., `apt-get install libsecp256k1-dev` on Ubuntu).
   - Alternative: Statically link libsecp256k1 during build if possible.

2. **Polymarket API rate limits and TLS certificates?**
   - Gamma API: Confirm polling every 10 minutes is compliant (check docs).
   - CLOB API: Implement 429 backoff as per FR-23 (deferred to Phase 2 order manager, but HTTP client should support it).
   - TLS: Ensure Zig http.Client trusts Polymarket's certificates (uses system CA store by default).

3. **WebSocket frame size limits for large order books?**
   - Recommendation: Set a reasonable max frame size (e.g., 1 MB) to prevent unbounded memory allocation.
   - Log a warning if max size exceeded; drop frame if needed.
