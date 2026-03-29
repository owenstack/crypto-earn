import { test, expect, describe } from "bun:test";

describe("createBot", () => {
  test("throws if TELEGRAM_BOT_TOKEN is not set", async () => {
    const original = Bun.env.TELEGRAM_BOT_TOKEN;
    delete Bun.env.TELEGRAM_BOT_TOKEN;

    try {
      // Fresh import to avoid module cache issues
      // We directly test the function behavior
      const { createBot } = await import("../src/telegram/bot.ts");
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
      const { createBot } = await import("../src/telegram/bot.ts");
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

  test("ALLOWED_IDS is populated from env", async () => {
    const original = Bun.env.TELEGRAM_ALLOWED_CHAT_IDS;

    try {
      Bun.env.TELEGRAM_ALLOWED_CHAT_IDS = "123,456,789";

      // Import fresh to pick up the new env var using query param to bypass cache
      const { isAllowedChatId } = await import(`../src/telegram/bot.ts?t=${Date.now()}`);

      // Test that allowed IDs are recognized
      expect(isAllowedChatId(123)).toBe(true);
      expect(isAllowedChatId(456)).toBe(true);
      expect(isAllowedChatId(789)).toBe(true);

      // Test that disallowed ID is rejected
      expect(isAllowedChatId(999)).toBe(false);
    } finally {
      if (original) {
        Bun.env.TELEGRAM_ALLOWED_CHAT_IDS = original;
      } else {
        delete Bun.env.TELEGRAM_ALLOWED_CHAT_IDS;
      }
    }
  });
});

describe("Phase 4 event push notifications", () => {
  test("registerEventPush is exported as a function", async () => {
    const { registerEventPush } = await import(`../src/telegram/bot.ts?push_test=${Date.now()}`);
    expect(registerEventPush).toBeDefined();
    expect(typeof registerEventPush).toBe("function");
  });

  test("isAllowedChatId guards push delivery", async () => {
    const original = Bun.env.TELEGRAM_ALLOWED_CHAT_IDS;
    Bun.env.TELEGRAM_ALLOWED_CHAT_IDS = "111,222";

    try {
      const { isAllowedChatId } = await import(`../src/telegram/bot.ts?push_guard=${Date.now()}`);
      expect(isAllowedChatId(111)).toBe(true);
      expect(isAllowedChatId(222)).toBe(true);
      expect(isAllowedChatId(999)).toBe(false);
    } finally {
      if (original) {
        Bun.env.TELEGRAM_ALLOWED_CHAT_IDS = original;
      } else {
        delete Bun.env.TELEGRAM_ALLOWED_CHAT_IDS;
      }
    }
  });
});
