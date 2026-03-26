/**
 * Telegram bot (Grammy) with chat-ID allowlist authentication.
 * All commands are routed through the IPC client.
 */
import { Bot, Context } from "grammy";
import type { IPCClient } from "../ipc/client";
import type { StatusPayload, HeartbeatPayload, PortfolioPayload, OrdersPayload } from "../ipc/types";

const ALLOWED_IDS = new Set(
  (Bun.env.TELEGRAM_ALLOWED_CHAT_IDS ?? "")
    .split(",")
    .map(s => s.trim())
    .filter(Boolean)
    .map(Number)
);

function isAllowed(ctx: Context): boolean {
  const id = ctx.chat?.id;
  return id !== undefined && ALLOWED_IDS.has(id);
}

export function isAllowedChatId(chatId: number): boolean {
  return ALLOWED_IDS.has(chatId);
}

function guard(handler: (ctx: Context) => Promise<void>) {
  return async (ctx: Context) => {
    if (!isAllowed(ctx)) {
      await ctx.reply("⛔ Unauthorized.");
      return;
    }
    try {
      await handler(ctx);
    } catch (err) {
      await ctx.reply(`❌ Error: ${err instanceof Error ? err.message : String(err)}`);
    }
  };
}

export function createBot(ipc: IPCClient): Bot {
  const token = Bun.env.TELEGRAM_BOT_TOKEN;
  if (!token) throw new Error("TELEGRAM_BOT_TOKEN not set");

  const bot = new Bot(token);

  bot.command("start", guard(async ctx => {
    await ctx.reply(
      "🤖 *CEX Engine Control*\n\n" +
      "/status — engine status\n" +
      "/portfolio — open positions\n" +
      "/orders — open orders\n" +
      "/config — current config",
      { parse_mode: "Markdown" }
    );
  }));

  bot.command("status", guard(async ctx => {
    if (!ipc.connected) {
      await ctx.reply("🔴 Engine IPC offline.");
      return;
    }
    const res = await ipc.request<StatusPayload>("status");
    const p = res.payload;
    await ctx.reply(
      `📊 *Engine Status*\n` +
      `• Engine: \`${p.engine}\`\n` +
      `• DB: \`${p.db}\`\n` +
      `• Uptime: \`${(p.uptime_ms / 1000).toFixed(1)}s\``,
      { parse_mode: "Markdown" }
    );
  }));

  bot.command("portfolio", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const res = await ipc.request<PortfolioPayload>("portfolio");
    const positions = res.payload.positions;
    if (!positions.length) {
      await ctx.reply("📭 No open positions.");
      return;
    }
    await ctx.reply(`📈 *Open Positions (${positions.length})*\n` + JSON.stringify(positions, null, 2), { parse_mode: "Markdown" });
  }));

  bot.command("orders", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const res = await ipc.request<OrdersPayload>("orders");
    const orders = res.payload.orders;
    if (!orders.length) {
      await ctx.reply("📭 No open orders.");
      return;
    }
    await ctx.reply(`📋 *Open Orders (${orders.length})*\n` + JSON.stringify(orders, null, 2), { parse_mode: "Markdown" });
  }));

  bot.command("config", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const res = await ipc.request("config.get");
    await ctx.reply(`⚙️ Config:\n\`\`\`json\n${JSON.stringify(res.payload, null, 2)}\n\`\`\``, { parse_mode: "Markdown" });
  }));

  return bot;
}
