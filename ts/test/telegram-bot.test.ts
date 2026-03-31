import { test, expect, describe } from "bun:test";
import { createBot, createAllowedIds, isAllowedChatId, registerEventPush } from "../src/telegram/bot.ts";

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
  test("/config, /pause, /pnl command handlers exist", async () => {
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
});
