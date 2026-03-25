//! Smoke test for module linkage.

const cex = @import("cex_zig");

test "module linkage smoke test" {
    _ = cex.types.Exchange.binance;
    _ = cex.channel.BoundedChannel(u32, 4);
    _ = cex.log.Level.info;
    _ = cex.config.Config{};
    _ = cex.http.HttpClient;
    _ = cex.gateway.GatewayError;
    _ = cex.gateway.binance.Adapter;
    _ = cex.gateway.bybit.Adapter;
    _ = cex.gateway.coinbase.Adapter;
    _ = cex.gateway.okx.Adapter;
    _ = cex.engine.ArbEngine;
    _ = cex.engine.BboStateTable;
}
