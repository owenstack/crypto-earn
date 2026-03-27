/**
 * Telegram bot (Grammy) with chat-ID allowlist authentication.
 * All commands are routed through the IPC client.
 */
import { Bot, Context } from "grammy";
import type { IPCClient } from "../ipc/client";
import type {
  StatusPayload,
  HeartbeatPayload,
  PortfolioPayload,
  OrdersPayload,
  HaltResponsePayload,
  ResumeResponsePayload,
  OrderPlaceResponsePayload,
  OrderCancelResponsePayload,
  OrderCancelAllResponsePayload,
  OrderPlaceRequestPayload,
  OrderCancelPayload,
} from "../ipc/types";

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
      "/config — current config\n" +
      "/trade — place an order\n" +
      "/cancel — cancel an order\n" +
      "/halt — emergency stop\n" +
      "/resume — resume trading",
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

  bot.command("trade", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const args = ctx.message?.text?.split(" ").slice(1) ?? [];
    if (args.length < 4) {
      await ctx.reply("Usage: /trade <market_id> <buy|sell> <price> <size> [order_type]");
      return;
    }
    const market_id = (args[0] ?? "").trim();
    const side_raw = (args[1] ?? "").trim().toLowerCase();
    const parsedPriceNum = Number(args[2]);
    const parsedSizeNum = Number(args[3]);
    const order_type_raw = (args[4] ?? "limit").trim().toLowerCase();

    if (!market_id) {
      await ctx.reply("❌ Invalid market_id. Please provide a non-empty market_id.");
      return;
    }

    if (side_raw !== "buy" && side_raw !== "sell") {
      await ctx.reply("❌ Invalid side. Use exactly 'buy' or 'sell'.");
      return;
    }

    if (!Number.isFinite(parsedPriceNum) || parsedPriceNum <= 0) {
      await ctx.reply("❌ Invalid price. Price must be a finite positive number.");
      return;
    }

    if (!Number.isFinite(parsedSizeNum) || parsedSizeNum <= 0) {
      await ctx.reply("❌ Invalid size. Size must be a finite positive number.");
      return;
    }

    const side: "buy" | "sell" = side_raw;
    const normalized_order_type: OrderPlaceRequestPayload["order_type"] = order_type_raw === "market" ? "market" : "limit";
    const parsedPrice = String(parsedPriceNum);
    const parsedSize = String(parsedSizeNum);

    const res = await ipc.request<OrderPlaceRequestPayload, OrderPlaceResponsePayload>("order.place", {
      market_id,
      side,
      size: parsedSize,
      price: parsedPrice,
      order_type: normalized_order_type,
    });
    const p = res.payload;
    await ctx.reply(
      `📝 *Order Result*\n` +
      `• Order ID: \`${p.order_id}\`\n` +
      `• Status: \`${p.status}\``,
      { parse_mode: "Markdown" }
    );
  }));

  bot.command("cancel", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const args = ctx.message?.text?.split(" ").slice(1) ?? [];
    if (args.length === 0) {
      await ctx.reply("Usage: /cancel <order_id> or /cancel all");
      return;
    }
    if (args[0] === "all") {
      const res = await ipc.request<OrderCancelAllResponsePayload>("order.cancel_all");
      await ctx.reply(`🗑️ Cancelled ${res.payload.cancelled_count} orders.`);
    } else {
      const order_id = args[0];
      if (!order_id) {
        await ctx.reply("Usage: /cancel <order_id> or /cancel all");
        return;
      }
      const res = await ipc.request<OrderCancelPayload, OrderCancelResponsePayload>("order.cancel", { order_id });
      await ctx.reply(`🗑️ Order ${res.payload.order_id}: ${res.payload.status}`);
    }
  }));

  bot.command("halt", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const res = await ipc.request<HaltResponsePayload>("halt");
    await ctx.reply(
      `🛑 *HALT*\n` +
      `• Status: \`${res.payload.status}\`\n` +
      `• Cancelled orders: ${res.payload.cancelled_orders}`,
      { parse_mode: "Markdown" }
    );
  }));

  bot.command("resume", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const res = await ipc.request<ResumeResponsePayload>("resume");
    await ctx.reply(`✅ Engine ${res.payload.status}.`);
  }));

  return bot;
}
