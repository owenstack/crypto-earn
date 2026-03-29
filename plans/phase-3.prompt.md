## Plan: Phase 3 Zig Strategies

Implement only PRD Phase 3 (Week 4): add a production-capable Zig strategy engine with WebSocket-driven evaluation, two strategies (news repricing + liquidity provision), strategy lifecycle controls over IPC, and Telegram strategy commands. Reuse completed Phase 2 order/risk/persistence paths so strategy signals always flow through existing risk checks and order manager controls.

**Steps**
1. Phase A - Strategy contracts and shared state
2. Define a new Zig strategy module at /home/owenstack/repos/personal/cex-zig/zig/src/strategy_engine.zig with shared types: Signal, StrategyName, StrategyEvaluationContext, StrategyStats, and StrategyConfig. Depends on none.
3. Add strategy-origin metadata to order placement path so each strategy-emitted order can be attributed for metrics. Update signatures in /home/owenstack/repos/personal/cex-zig/zig/src/order_manager.zig and any call sites. Depends on step 2.
4. Add DB helpers for signal and strategy metrics persistence in /home/owenstack/repos/personal/cex-zig/zig/src/db.zig: insertStrategySignal, queryStrategyStats, queryRecentSignalsByStrategy, and optional updateStrategyState helpers. Depends on step 2.

5. Phase B - WebSocket feed completion and event pipeline
6. Complete WebSocket upgrade/read loop in /home/owenstack/repos/personal/cex-zig/zig/src/websocket.zig (performUpgrade + message parsing + callback dispatch) so live CLOB updates are consumable in-process. Depends on step 2.
7. Introduce a bounded event queue for price updates and strategy signals in /home/owenstack/repos/personal/cex-zig/zig/src/main.zig to decouple network ingest from evaluation/order submission. Depends on step 6.
8. Wire market scanner subscriptions into the WebSocket client by mapping scanner-tracked market token IDs to subscribe calls in /home/owenstack/repos/personal/cex-zig/zig/src/market_scanner.zig and /home/owenstack/repos/personal/cex-zig/zig/src/main.zig. Depends on step 6.

9. Phase C - News repricing strategy (real API)
10. Add a dedicated external-probability client module at /home/owenstack/repos/personal/cex-zig/zig/src/news_sources.zig with a real provider integration (first provider implementation plus provider abstraction for future expansion). Depends on step 2.
11. Implement news repricing evaluator in /home/owenstack/repos/personal/cex-zig/zig/src/strategy_engine.zig: compare external probability vs market mid, compute confidence, emit directional signal when delta exceeds threshold, and persist signal metadata. Depends on steps 2, 10.
12. Implement repricing-edge collapse cancellation: on each subsequent evaluation for a market/order pair, cancel open strategy order if delta falls back under threshold before fill. Use /home/owenstack/repos/personal/cex-zig/zig/src/order_manager.zig + in-memory signal-order mapping in /home/owenstack/repos/personal/cex-zig/zig/src/strategy_engine.zig. Depends on step 11.

13. Phase D - Liquidity provision strategy
14. Implement spread evaluator in /home/owenstack/repos/personal/cex-zig/zig/src/strategy_engine.zig that emits paired bid/ask limit signals when spread exceeds configured minimum. Depends on steps 2, 6.
15. Add paired-order lifecycle rules: if one side fills, cancel the opposite side; if spread narrows below exit threshold, cancel both. Integrate with /home/owenstack/repos/personal/cex-zig/zig/src/order_manager.zig and signal-order tracking state. Depends on step 14.
16. Enforce risk consistency by routing every strategy-generated order through existing placeOrder path (no bypass), so max position/exposure/open-order checks still apply. Depends on steps 14, 15.

17. Phase E - Runtime orchestration and controls
18. Add a dedicated strategy worker thread in /home/owenstack/repos/personal/cex-zig/zig/src/main.zig that consumes price events, runs enabled strategies, and dispatches accepted signals to order manager. Depends on steps 7, 11, 14.
19. Respect halt/resume semantics from Phase 2: halted state blocks strategy evaluation dispatch and clears pending strategy queue safely. Integrate with /home/owenstack/repos/personal/cex-zig/zig/src/main.zig and /home/owenstack/repos/personal/cex-zig/zig/src/ipc.zig. Depends on step 18.
20. Track per-strategy runtime stats (signals, accepted/rejected orders, cancels, realized pnl estimate proxy) in strategy engine state and expose snapshot getters. Depends on step 18.

21. Phase F - IPC and TypeScript control plane
22. Extend Zig IPC message constants in /home/owenstack/repos/personal/cex-zig/zig/src/ipc_types.zig with strategy.enable, strategy.disable, strategy.list, and strategy.signal.event payload formats. Depends on step 2.
23. Add Zig IPC handlers in /home/owenstack/repos/personal/cex-zig/zig/src/ipc.zig for strategy enable/disable/list backed by strategy engine state. Depends on steps 18, 22.
24. Mirror these contracts in /home/owenstack/repos/personal/cex-zig/ts/src/ipc/types.ts and add typed client helpers in /home/owenstack/repos/personal/cex-zig/ts/src/ipc/client.ts. Depends on step 22.
25. Add Telegram commands in /home/owenstack/repos/personal/cex-zig/ts/src/telegram/bot.ts: /strategy list, /strategy enable <name>, /strategy disable <name> using existing chat guard and IPC request flow. Depends on step 24.

26. Phase G - Tests and validation
27. Add Zig tests in /home/owenstack/repos/personal/cex-zig/zig/src/tests.zig (or focused test files) for: news threshold trigger, confidence bounds, repricing cancel-on-collapse, LP pair lifecycle, enable/disable gating, and halt suppression. Depends on steps 11-20.
28. Add TS tests for new IPC contracts and Telegram command behavior in /home/owenstack/repos/personal/cex-zig/ts/test/ipc-client.test.ts and /home/owenstack/repos/personal/cex-zig/ts/test/telegram-bot.test.ts. Depends on steps 24-25.
29. Execute full verification run and manual scenario checks (listed below). Depends on all prior steps.

**Relevant files**
- /home/owenstack/repos/personal/cex-zig/zig/src/main.zig - add strategy worker thread, websocket wiring, queueing, halt gating integration.
- /home/owenstack/repos/personal/cex-zig/zig/src/websocket.zig - complete websocket handshake and read loop; parse updates and invoke callback.
- /home/owenstack/repos/personal/cex-zig/zig/src/market_scanner.zig - provide tracked market identifiers needed for websocket subscriptions.
- /home/owenstack/repos/personal/cex-zig/zig/src/strategy_engine.zig - new phase 3 core module with strategy registry, evaluators, state, and signal generation.
- /home/owenstack/repos/personal/cex-zig/zig/src/news_sources.zig - new external probability API client abstraction and first real provider.
- /home/owenstack/repos/personal/cex-zig/zig/src/order_manager.zig - strategy-origin tagging and cancellation hooks.
- /home/owenstack/repos/personal/cex-zig/zig/src/db.zig - strategy signal/stats persistence helpers.
- /home/owenstack/repos/personal/cex-zig/zig/src/ipc_types.zig - add phase 3 strategy message types.
- /home/owenstack/repos/personal/cex-zig/zig/src/ipc.zig - implement strategy command dispatch handlers.
- /home/owenstack/repos/personal/cex-zig/ts/src/ipc/types.ts - TS mirror for strategy message types/payloads.
- /home/owenstack/repos/personal/cex-zig/ts/src/ipc/client.ts - typed strategy helper requests.
- /home/owenstack/repos/personal/cex-zig/ts/src/telegram/bot.ts - strategy command handlers.
- /home/owenstack/repos/personal/cex-zig/zig/src/tests.zig - Zig strategy behavior tests.
- /home/owenstack/repos/personal/cex-zig/ts/test/ipc-client.test.ts - TS IPC tests for strategy commands.
- /home/owenstack/repos/personal/cex-zig/ts/test/telegram-bot.test.ts - Telegram command tests.

**Verification**
1. Build and unit tests: run zig build and zig build test in /home/owenstack/repos/personal/cex-zig/zig, then bun test in /home/owenstack/repos/personal/cex-zig/ts.
2. WebSocket flow: confirm live price updates are received and trigger strategy evaluations with structured logs.
3. News repricing behavior: verify signal creation when external delta exceeds threshold and automatic cancellation when delta collapses before fill.
4. Liquidity provision behavior: verify paired orders are placed when spread is wide and opposite side is canceled on one-side fill.
5. Risk invariants: verify strategy-originated orders still pass through risk gate and rejections are logged/persisted.
6. Control commands: verify /strategy list, /strategy enable, /strategy disable work end-to-end through TS IPC to Zig.
7. Halt safety: verify halt prevents further strategy dispatch and resume restores dispatch.

**Decisions**
- Included scope: Phase 3 only (strategies) plus required IPC/Telegram wiring to operate strategy controls.
- Trigger model: WebSocket-driven evaluation in this phase.
- News source: real external API integration now (not stub-only).
- Repricing edge collapse: cancel pending repricing orders on next evaluation cycle if edge disappears.

**Further Considerations**
1. External provider selection: choose one primary provider first (Metaculus or Kalshi mirror) to keep API risk bounded; keep provider abstraction for later additions.
2. Queue/backpressure policy: cap event queue and drop/coalesce stale per-market price updates to avoid evaluation lag bursts during volatility.
3. Metrics definition: agree whether strategy pnl in list output is realized-only in Phase 3 to avoid misleading unrealized estimates.