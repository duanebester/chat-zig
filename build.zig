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

    exe.linkLibC();

    if (target.result.os.tag == .macos) {
        exe.linkFramework("Cocoa");
        exe.linkFramework("Metal");
        exe.linkFramework("MetalKit");
        exe.linkFramework("QuartzCore");
        exe.linkFramework("CoreText");
        exe.linkFramework("CoreGraphics");
        exe.linkFramework("CoreFoundation");
        exe.linkFramework("Foundation");
        exe.linkFramework("AppKit");
        exe.linkFramework("Security");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ChatZig");
    run_step.dependOn(&run_cmd.step);
}
