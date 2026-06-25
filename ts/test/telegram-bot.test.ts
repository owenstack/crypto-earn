import { test, expect, describe } from "bun:test";
import {
  createBot,
  createAllowedIds,
  isAllowedChatId,
  registerEventPush,
  shouldNotifyTelegramPush,
  formatFundingSnapshot,
  formatArbEvents,
} from "../src/telegram/bot.ts";
import type { Envelope } from "../src/ipc/types.ts";

describe("createBot", () => {
  test("throws if TELEGRAM_BOT_TOKEN is not set", async () => {
    const original = Bun.env.TELEGRAM_BOT_TOKEN;
    delete Bun.env.TELEGRAM_BOT_TOKEN;

    try {
      const mockIpc = { connected: false, request: async () => ({}) } as any;
      expect(() => createBot(mockIpc)).toThrow("TELEGRAM_BOT_TOKEN not set");
    } finally {
      if (original) Bun.env.TELEGRAM_BOT_TOKEN = original;
    }
  });

  test("returns a Bot instance when token is set", async () => {
    const original = Bun.env.TELEGRAM_BOT_TOKEN;
    Bun.env.TELEGRAM_BOT_TOKEN = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11";

    try {
      const mockIpc = { connected: false, request: async () => ({}) } as any;
      const bot = createBot(mockIpc);
      expect(bot).toBeDefined();
      expect(bot.token).toBe("123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11");
    } finally {
      if (original) {
        Bun.env.TELEGRAM_BOT_TOKEN = original;
      } else {
        delete Bun.env.TELEGRAM_BOT_TOKEN;
      }
    }
  });

  test("createAllowedIds parses env-like input", () => {
    const allowed = createAllowedIds("123,456,789");
    expect(isAllowedChatId(123, allowed)).toBe(true);
    expect(isAllowedChatId(456, allowed)).toBe(true);
    expect(isAllowedChatId(789, allowed)).toBe(true);
    expect(isAllowedChatId(999, allowed)).toBe(false);
  });
});

describe("Phase 5 commands", () => {
  test("/config, /pause, /pnl, /funding, /arb command handlers exist", async () => {
    const original = Bun.env.TELEGRAM_BOT_TOKEN;
    Bun.env.TELEGRAM_BOT_TOKEN = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11";

    try {
      const mockIpc = {
        connected: true,
        request: async () => ({ v: 1, id: "1", ts: Date.now(), type: "test", payload: {} }),
        configSet: async () => ({ v: 1, id: "1", ts: Date.now(), type: "config.set.response", payload: { key: "k", old_value: null, new_value: "v" } }),
        pause: async () => ({ v: 1, id: "1", ts: Date.now(), type: "pause.response", payload: { status: "paused" } }),
        pnl: async () => ({ v: 1, id: "1", ts: Date.now(), type: "pnl.response", payload: { window: "today", realized_pnl: "0.00", unrealized_pnl: "0.00", win_count: 0, loss_count: 0, avg_win: "0.00", avg_loss: "0.00" } }),
      } as any;
      const bot = createBot(mockIpc);
      expect(bot).toBeDefined();
    } finally {
      if (original) {
        Bun.env.TELEGRAM_BOT_TOKEN = original;
      } else {
        delete Bun.env.TELEGRAM_BOT_TOKEN;
      }
    }
  });

  test("formats funding snapshots for Telegram operators", () => {
    const msg = formatFundingSnapshot({
      funding: [
        {
          asset: "BTC",
          rate: 0.000125,
          next_payment_ts: 1_700_000_000,
          recorded_at: 1_699_999_900,
        },
      ],
    });

    expect(msg).toContain("<b>Funding Snapshot</b>");
    expect(msg).toContain("BTC");
    expect(msg).toContain("+0.0125%");
    expect(msg).toContain("+1.25 bps");
    expect(msg).toContain("2023-11-14 22:13:20 UTC");
  });

  test("formats arb events for Telegram operators", () => {
    const msg = formatArbEvents({
      events: [
        {
          asset: "ETH",
          binance_mid: 3200,
          hl_mid: 3198.5,
          delta_bps: -4.6875,
          order_id: "order-123456789",
          realised_pnl: 1.23456,
          submit_ns: 10_000_000,
          fill_ns: 35_000_000,
          created_at: 1_700_000_000,
        },
      ],
    });

    expect(msg).toContain("<b>Arb Events</b>");
    expect(msg).toContain("ETH");
    expect(msg).toContain("-4.69bps");
    expect(msg).toContain("+1.2346");
    expect(msg).toContain("lat   25.0ms");
    expect(msg).toContain("order-123456");
  });
});

describe("Phase 4 event push notifications", () => {
  test("registerEventPush is exported as a function", () => {
    expect(registerEventPush).toBeDefined();
    expect(typeof registerEventPush).toBe("function");
  });

  test("isAllowedChatId guards push delivery", () => {
    const allowed = createAllowedIds("111,222");
    expect(isAllowedChatId(111, allowed)).toBe(true);
    expect(isAllowedChatId(222, allowed)).toBe(true);
    expect(isAllowedChatId(999, allowed)).toBe(false);
  });

  test("rejected-order pushes are throttled by signature", () => {
    const env: Envelope = {
      v: 1,
      id: "evt-1",
      ts: Date.now(),
      type: "event.order.rejected",
      payload: {
        order_id: "o-1",
        market_id: "m-1",
        side: "sell",
        reason: "BalanceCommitmentExceeded",
      },
    };

    expect(shouldNotifyTelegramPush(env, 1_000)).toBe(true);
    expect(shouldNotifyTelegramPush(env, 2_000)).toBe(false);
    expect(shouldNotifyTelegramPush(env, 302_000)).toBe(true);
  });

  test("non-rejection event pushes are not throttled", () => {
    const env: Envelope = {
      v: 1,
      id: "evt-2",
      ts: Date.now(),
      type: "event.engine.halted",
      payload: {
        status: "halted",
        cancelled_orders: 2,
      },
    };

    expect(shouldNotifyTelegramPush(env, 1_000)).toBe(true);
    expect(shouldNotifyTelegramPush(env, 2_000)).toBe(true);
  });
});
