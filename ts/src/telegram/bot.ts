/**
 * Telegram bot (Grammy) with chat-ID allowlist authentication.
 * All commands are routed through the IPC client.
 */
import { Bot, Context } from "grammy";
import type { IPCClient } from "../ipc/client";
import type { Envelope, EventMessageType } from "../ipc/types";
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
  StrategyListResponsePayload,
  ConfigSetResponsePayload,
  PauseResponsePayload,
  PnlResponsePayload,
  PnlWindow,
  ConfigPayload,
} from "../ipc/types";

export function createAllowedIds(raw: string): Set<number> {
  return new Set(
    raw
      .split(",")
      .map(s => s.trim())
      .filter(Boolean)
      .map(Number)
      .filter(Number.isFinite)
  );
}

const ALLOWED_IDS = createAllowedIds(Bun.env.TELEGRAM_ALLOWED_CHAT_IDS ?? "");

function isAllowed(ctx: Context): boolean {
  const id = ctx.chat?.id;
  return id !== undefined && ALLOWED_IDS.has(id);
}

export function isAllowedChatId(chatId: number, allowedIds: Set<number> = ALLOWED_IDS): boolean {
  return allowedIds.has(chatId);
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

// Phase 4: Event push notification support
const DEDUP_MAX_SIZE = 500;
const recentEventIds = new Set<string>();

/**
 * Deduplicates event IDs with a bounded FIFO set.
 * Capacity is DEDUP_MAX_SIZE; once exceeded, we evict one oldest ID at a time.
 * Under sustained load the set intentionally stays near-full, which is fine
 * because event IDs are monotonic and old IDs are least likely to repeat.
 */
function dedup(eventId: string): boolean {
  if (recentEventIds.has(eventId)) return true;
  recentEventIds.add(eventId);
  if (recentEventIds.size > DEDUP_MAX_SIZE) {
    const first = recentEventIds.values().next().value;
    if (first) recentEventIds.delete(first);
  }
  return false;
}

function escapeHtml(value: unknown): string {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function fmt(value: unknown, fallback = "unknown"): string {
  if (value === undefined || value === null || value === "") return fallback;
  return escapeHtml(value);
}

function formatEvent(env: Envelope): string | null {
  const p = env.payload as Record<string, unknown>;
  switch (env.type as EventMessageType) {
    case "event.order.placed":
      return `📝 <b>Order Placed</b>\n• ID: <code>${fmt(p.order_id)}</code>\n• Market: <code>${fmt(p.market_id)}</code>\n• Side: ${fmt(p.side)}\n• Size: ${fmt(p.size)} @ ${fmt(p.price)}`;
    case "event.order.filled":
      return `✅ <b>Order Filled</b>\n• ID: <code>${fmt(p.order_id)}</code>\n• Market: <code>${fmt(p.market_id)}</code>\n• Side: ${fmt(p.side)}\n• Filled: ${fmt(p.fill_size)} @ ${fmt(p.fill_price)}\n• Realized P&L: ${fmt(p.realized_pnl, "N/A")}`;
    case "event.order.partially_filled":
      return `⏳ <b>Order Partially Filled</b>\n• ID: <code>${fmt(p.order_id)}</code>\n• Market: <code>${fmt(p.market_id)}</code>\n• Side: ${fmt(p.side)}\n• Filled: ${fmt(p.fill_size)} @ ${fmt(p.fill_price)}\n• Remaining: ${fmt(p.remaining_size)}`;
    case "event.order.cancelled":
      return `🗑️ <b>Order Cancelled</b>\n• ID: <code>${fmt(p.order_id)}</code>${p.market_id ? `\n• Market: <code>${fmt(p.market_id)}</code>` : ""}`;
    case "event.order.rejected":
      return `⚠️ <b>Order Rejected</b>\n• ID: <code>${fmt(p.order_id)}</code>\n• Market: <code>${fmt(p.market_id)}</code>\n• Reason: ${fmt(p.reason)}`;
    case "event.risk.rejection":
      return `🛡️ <b>Risk Rejection</b>\n• Order: <code>${fmt(p.order_id)}</code>\n• Market: <code>${fmt(p.market_id)}</code>\n• Check: ${fmt(p.check_name)}\n• Reason: ${fmt(p.reason)}`;
    case "event.engine.halted":
      return `🛑 <b>Engine HALTED</b>${p.cancelled_orders !== undefined ? `\n• Cancelled orders: ${fmt(p.cancelled_orders, "0")}` : ""}`;
    case "event.engine.resumed":
      return `✅ <b>Engine Resumed</b>`;
    default:
      return null;
  }
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
      "/config — get or set config\n" +
      "/trade — place an order\n" +
      "/cancel — cancel an order\n" +
      "/strategy — manage strategies\n" +
      "/pnl — profit & loss report\n" +
      "/pause — pause strategy evaluation\n" +
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
    const args = ctx.message?.text?.split(" ").slice(1) ?? [];
    const subcommand = (args[0] ?? "").trim().toLowerCase();

    if (subcommand === "set") {
      const key = (args[1] ?? "").trim();
      const value = args.slice(2).join(" ").trim();
      if (!key || !value) {
        await ctx.reply("Usage: /config set <key> <value>");
        return;
      }
      const res = await ipc.configSet(key, value);
      const p = res.payload;
      await ctx.reply(
        `⚙️ Config updated\n` +
        `• Key: \`${p.key}\`\n` +
        `• Old: \`${p.old_value ?? "null"}\`\n` +
        `• New: \`${p.new_value}\``,
        { parse_mode: "Markdown" }
      );
    } else {
      // Default: get all config
      const res = await ipc.request("config.get");
      await ctx.reply(`⚙️ Config:\n\`\`\`json\n${JSON.stringify(res.payload, null, 2)}\n\`\`\``, { parse_mode: "Markdown" });
    }
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

  bot.command("strategy", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const args = ctx.message?.text?.split(" ").slice(1) ?? [];
    const subcommand = (args[0] ?? "").trim().toLowerCase();

    if (subcommand === "list" || subcommand === "") {
      const res = await ipc.strategyList();
      const strategies = res.payload.strategies;
      if (!strategies.length) {
        await ctx.reply("📭 No strategies configured.");
        return;
      }
      const lines = strategies.map(s =>
        `• ${s.name}: ${s.enabled ? "✅ enabled" : "⏸️ disabled"}\n` +
        `  signals=${s.stats.signals_emitted} accepted=${s.stats.orders_accepted} rejected=${s.stats.orders_rejected}`
      );
      await ctx.reply(`📊 Strategies\n\n${lines.join("\n")}`);
    } else if (subcommand === "enable") {
      const name = (args[1] ?? "").trim();
      if (name !== "news_repricing" && name !== "liquidity_provision") {
        await ctx.reply("Usage: /strategy enable <news_repricing|liquidity_provision>");
        return;
      }
      const res = await ipc.strategyEnable(name);
      await ctx.reply(`✅ Strategy \`${res.payload.name}\` enabled.`, { parse_mode: "Markdown" });
    } else if (subcommand === "disable") {
      const name = (args[1] ?? "").trim();
      if (name !== "news_repricing" && name !== "liquidity_provision") {
        await ctx.reply("Usage: /strategy disable <news_repricing|liquidity_provision>");
        return;
      }
      const res = await ipc.strategyDisable(name);
      await ctx.reply(`⏸️ Strategy \`${res.payload.name}\` disabled.`, { parse_mode: "Markdown" });
    } else {
      await ctx.reply(
        "Usage:\n" +
        "/strategy list — show all strategies\n" +
        "/strategy enable <name> — enable a strategy\n" +
        "/strategy disable <name> — disable a strategy"
      );
    }
  }));

  bot.command("pause", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const res = await ipc.pause();
    await ctx.reply(`⏸️ Engine ${res.payload.status}. Open orders preserved.\nUse /resume to resume trading.`);
  }));

  bot.command("pnl", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const args = ctx.message?.text?.split(" ").slice(1) ?? [];
    const windowArg = (args[0] ?? "today").trim().toLowerCase();

    const validWindows: PnlWindow[] = ["today", "7d", "30d", "all"];
    if (!validWindows.includes(windowArg as PnlWindow)) {
      await ctx.reply("Usage: /pnl [today|7d|30d|all]");
      return;
    }

    const window = windowArg as PnlWindow;
    const res = await ipc.pnl(window);
    const p = res.payload;
    await ctx.reply(
      `📊 *P&L — ${p.window}*\n` +
      "```\n" +
      `Realized P&L:  ${p.realized_pnl}\n` +
      `Unrealized:    ${p.unrealized_pnl}\n` +
      `Wins:          ${p.win_count}\n` +
      `Losses:        ${p.loss_count}\n` +
      `Avg Win:       ${p.avg_win}\n` +
      `Avg Loss:      ${p.avg_loss}\n` +
      "```",
      { parse_mode: "Markdown" }
    );
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
    await ctx.reply(`✅ Engine ${res.payload.status}. Trading and strategy evaluation active.`);
  }));

  return bot;
}

/** Register event push notifications for the bot. Call after bot.start(). */
export function registerEventPush(ipc: IPCClient, bot: InstanceType<typeof Bot>): void {
  ipc.onEvent("*", async (env: Envelope) => {
    if (dedup(env.id)) return;
    const text = formatEvent(env);
    if (!text) return;

    const chatIds = Array.from(ALLOWED_IDS);
    for (const chatId of chatIds) {
      try {
        await bot.api.sendMessage(chatId, text, { parse_mode: "HTML" });
      } catch (err) {
        console.error(JSON.stringify({
          ts: Date.now(),
          level: "WARN",
          component: "telegram",
          msg: `push notification failed for chat ${chatId}: ${err instanceof Error ? err.message : String(err)}`,
        }));
      }
    }
  });
}
