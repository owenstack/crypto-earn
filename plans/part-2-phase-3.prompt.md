Phase 3 — Strategy Integrity (Kalshi WS Primary, Kalshi REST Fallback, Manifold Fallback Without API Key)

Phase 3 focuses on two main areas: (1) ensuring the news-repricing strategy uses an independent probability source, and (2) adding robust inventory management and paired-leg cancel-on-fill for the liquidity-provision (LP) strategy. This phase is critical for strategy correctness and risk control.
- News-repricing strategy uses Kalshi WebSocket as the primary probability source, with HTTP polling fallback.
- Fill detection uses Polymarket user-stream WebSocket as primary, with REST polling fallback.
- LP inventory management and paired-leg cancel-on-fill as previously specified.

---

1. News-Repricing: Kalshi WebSocket + Kalshi REST + Manifold Fallback

1.1. Implement zig/src/kalshi_ws.zig:
  - Kalshi WebSocket client per Kalshi docs.
  - Authenticate, subscribe, parse market probability updates.

1.2. Refactor probability provider:
  - In probability_provider.zig, use Kalshi WebSocket as primary.
  - If a Kalshi API key is configured and WebSocket is unavailable or has no usable estimates, fall back to Kalshi REST polling.
  - If there is no Kalshi API key, fall back to Manifold Markets polling automatically.
  - On reconnect, resume using WebSocket data.

1.3. Store latest estimates in a mutex-protected buffer, regardless of source.

1.4. Integrate with strategy:
  - In main.zig, spawn Kalshi WebSocket client and fallback poller.
  - evaluateNewsSignals() always uses the freshest available estimate.

1.5. Remove all Polymarket outcome_prices dependencies from news-repricing.

1.6. Add tests:
  - Unit/integration tests for both WebSocket and HTTP fallback.
  - Simulate WebSocket failure and verify fallback.

1.7. Document the simplified operator config in docs/probability-source.md:
  - The only required operator input is `kalshi_api_key`.
  - Remove references to `market_id_field`, `probability_field`, and other generic source-schema config.

---

2. Fill Detection: Polymarket User-Stream WebSocket + REST Polling Fallback

2.1. Implement/extend zig/src/polymarket_ws.zig:
  - User-stream WebSocket client per Polymarket docs.
  - Authenticate, subscribe, parse fill/cancel events.

2.2. Refactor fill detection:
  - Use WebSocket as primary fill event source.
  - If WebSocket is unavailable/disconnected, fall back to REST polling (existing logic in fill_poller.zig).
  - On reconnect, resume using WebSocket.

2.3. On fill/cancel event, call processFill(), update DB/positions, and publish IPC events.

2.4. Add tests:
  - Unit/integration tests for both WebSocket and REST fallback.
  - Simulate WebSocket failure and verify fallback.

2.5. Update documentation to reflect dual-path fill detection.

---

3. LP Inventory Management & Paired-Leg Cancel-on-Fill

3.1. DB migration (MIGRATION_008):
  - Add max_net_position_usd to runtime_config, net_position_usd to positions, lp_pair_order_id to orders.

3.2. Inventory tracking in strategy_engine.zig:
  - Track per-market net position.
  - Block LP signals if limit exceeded.

3.3. Paired order management:
  - Link bid/ask pairs on placement.
  - On fill, cancel paired order via order manager.

3.4. Inventory update on fill.

3.5. IPC for inventory snapshot.

3.6. Tests for inventory logic and paired cancel.

---

Relevant files
- zig/src/kalshi_ws.zig — Kalshi WebSocket client
- zig/src/probability_provider.zig — fallback logic
- zig/src/polymarket_ws.zig — Polymarket user-stream client
- zig/src/fill_poller.zig — fallback logic
- zig/src/strategy_engine.zig — inventory, paired order logic
- zig/src/order_manager.zig — cancel logic
- zig/src/db.zig — migrations
- zig/tests.zig — new/updated tests
- docs/probability-source.md — both data paths

---

Verification
1. Unit/integration tests for both WebSocket and polling fallback for Kalshi and Polymarket.
2. Manual test: simulate WebSocket outage, verify fallback and recovery.
3. Manual test: Kalshi price update triggers news-repricing.
4. Manual test: Polymarket fill event updates positions and triggers paired cancel.
5. DB migration applies cleanly.
6. All new/affected tests pass.

---

Decisions
- WebSocket is always primary; polling is only a fallback.
- Fallback is automatic and seamless; operator is notified on fallback activation.
- All logic is robust to reconnects and failover.

---

Further Considerations
1. Ensure operator logs/alerts when fallback is active.
2. Document operational requirements for both WebSocket and polling credentials.
3. Consider metrics for time spent in fallback mode for monitoring.
