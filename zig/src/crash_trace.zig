const std = @import("std");

const c = @cImport({
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

const RING_SIZE: usize = 64;
const MAX_LINE: usize = 192;

var g_mutex: std.Thread.Mutex = .{};
var g_ring: [RING_SIZE][MAX_LINE]u8 = undefined;
var g_ring_len: [RING_SIZE]usize = [_]usize{0} ** RING_SIZE;
var g_head: usize = 0;
var g_count: usize = 0;
var g_installed = false;

pub fn install() void {
    if (g_installed) return;
    g_installed = true;

    installOne(c.SIGSEGV);
    installOne(c.SIGABRT);
    installOne(c.SIGBUS);
    installOne(c.SIGILL);
}

pub fn breadcrumb(component: []const u8, comptime fmt: []const u8, args: anytype) void {
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "<overflow>";

    var line_buf: [MAX_LINE]u8 = undefined;
    const ts = std.time.milliTimestamp();
    const tid = std.Thread.getCurrentId();
    const line = std.fmt.bufPrint(&line_buf, "{d} tid={d} {s} {s}", .{
        ts,
        tid,
        component,
        msg,
    }) catch return;

    g_mutex.lock();
    defer g_mutex.unlock();

    @memcpy(g_ring[g_head][0..line.len], line);
    g_ring_len[g_head] = line.len;
    g_head = (g_head + 1) % RING_SIZE;
    if (g_count < RING_SIZE) g_count += 1;
}

fn installOne(sig: c_int) void {
    var action: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    action.__sigaction_handler.sa_handler = crashHandler;
    action.sa_flags = 0;
    _ = c.sigemptyset(&action.sa_mask);
    _ = c.sigaction(sig, &action, null);
}

fn crashHandler(sig: c_int) callconv(.c) void {
    const banner = "FATAL: signal received, dumping crash breadcrumbs\n";
    _ = c.write(2, banner.ptr, banner.len);

    var idx: usize = if (g_count < RING_SIZE) 0 else g_head;
    var remaining = g_count;
    while (remaining > 0) : (remaining -= 1) {
        const len = g_ring_len[idx];
        if (len > 0) {
            _ = c.write(2, g_ring[idx][0..len].ptr, len);
            _ = c.write(2, "\n".ptr, 1);
        }
        idx = (idx + 1) % RING_SIZE;
    }

    var reset_action: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    reset_action.__sigaction_handler.sa_handler = c.SIG_DFL;
    reset_action.sa_flags = 0;
    _ = c.sigemptyset(&reset_action.sa_mask);
    _ = c.sigaction(sig, &reset_action, null);
    _ = c.raise(sig);
}
