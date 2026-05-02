import { serve } from "bun";
import { IPCClient } from "./ipc/client";
import { createBot, registerEventPush } from "./telegram/bot";
import { dashboardRoutes } from "./dashboard/server";
import indexHtml from "./index.html";

// 1. Initialize IPC Client to talk to Zig
const ipc = new IPCClient();

async function connectIpcWithRetry() {
  for (;;) {
    try {
      await ipc.connect();
      return;
    } catch (err) {
      console.warn(`⚠️ IPC initial connection failed: ${err instanceof Error ? err.message : String(err)}`);
      await new Promise(resolve => setTimeout(resolve, 5000));
    }
  }
}

void connectIpcWithRetry();

// 2. Initialize Telegram Bot (if token provided)
if (Bun.env.TELEGRAM_BOT_TOKEN) {
  const bot = createBot(ipc);
  bot.start({
    onStart: async (botInfo) => {
      console.log(`🤖 Telegram bot started as @${botInfo.username}`);
      // Subscribe to engine events for push notifications
      try {
        await ipc.subscribe();
        try {
          registerEventPush(ipc, bot);
          console.log("📡 Event push notifications active");
        } catch (pushErr) {
          await ipc.unsubscribe();
          throw pushErr;
        }
      } catch (err) {
        console.warn(`⚠️ Event subscription failed: ${err instanceof Error ? err.message : String(err)}`);
      }
    },
  });
} else {
  console.warn("⚠️ TELEGRAM_BOT_TOKEN not set, skipping Telegram bot initialization.");
}

// 3. Initialize Web Server (API + Frontend)
const apiRoutes = dashboardRoutes(ipc);

const server = serve({
  port: Bun.env.DASHBOARD_PORT || 3000,
  routes: {
    // Spread the API routes object
    ...apiRoutes,
    
    // Serve index.html for all unmatched routes (SPA fallback)
    "/*": indexHtml,
  },
  development: Bun.env.NODE_ENV !== "production" && {
    hmr: true,
  },
});

console.log(`🚀 Control Plane running at ${server.url}`);

// Handle graceful shutdown
process.on("SIGINT", async () => {
  console.log("Shutting down...");
  try { await ipc.unsubscribe(); } catch { /* best effort */ }
  ipc.disconnect();
  server.stop();
  process.exit(0);
});
