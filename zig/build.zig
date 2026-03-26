const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (root.zig) — kept for test re-use
    const mod = b.addModule("zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main engine executable
    const exe = b.addExecutable(.{
        .name = "cex-engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig", .module = mod },
            },
        }),
    });

    // Link SQLite3 system library + libc
    exe.linkLibC();
    exe.linkSystemLibrary("sqlite3");

    b.installArtifact(exe);

    // `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the engine");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    // Integration test suite (src/tests.zig) — needs sqlite3 + libc
    const suite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    suite_tests.linkLibC();
    suite_tests.linkSystemLibrary("sqlite3");

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(suite_tests).step);
}
