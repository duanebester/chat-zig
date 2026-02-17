const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gooey_dep = b.dependency("gooey", .{
        .target = target,
        .optimize = optimize,
    });
    const gooey_mod = gooey_dep.module("gooey");

    const exe = b.addExecutable(.{
        .name = "chat-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_mod },
            },
        }),
    });

    // Gooey's module links macOS frameworks (AppKit, Metal, CoreText, etc.)
    // transitively — no manual linkFramework ceremony needed here.
    // Security is consumer-specific: std.http needs it for TLS on macOS.
    if (target.result.os.tag == .macos) {
        exe.linkFramework("Security");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ChatZig");
    run_step.dependOn(&run_cmd.step);
}
