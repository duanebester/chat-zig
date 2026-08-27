const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gooey_dep = b.dependency("gooey", .{
        .target = target,
        .optimize = optimize,
    });
    const gooey_mod = gooey_dep.module("gooey");

    // =========================================================================
    // Executable
    // =========================================================================

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gooey", .module = gooey_mod },
        },
    });

    // Gooey's module links macOS frameworks (AppKit, Metal, CoreText, etc.)
    // transitively — no manual linkFramework ceremony needed here.
    // Security is consumer-specific: std.http needs it for TLS on macOS.
    // Zig 0.16 moved linkFramework off Compile steps; link it on the module.
    if (target.result.os.tag == .macos) {
        exe_mod.linkFramework("Security", .{});
        exe_mod.linkFramework("CoreAudio", .{});
        exe_mod.linkFramework("CoreFoundation", .{});
        exe_mod.linkFramework("AudioToolbox", .{});
    }

    const exe = b.addExecutable(.{
        .name = "chat-zig",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ChatZig");
    run_step.dependOn(&run_cmd.step);

    // =========================================================================
    // Tests
    // =========================================================================
    //
    // `zig build test` runs the unit tests embedded in `src/http.zig`
    // (JSON escaping, response parsing, MIME type detection, base64, file
    // upload lifecycle, etc.). The tests don't hit the network — they
    // validate the pure helpers — so they're fast and safe to run on every
    // build.
    //
    // We point the test binary at `http.zig` directly rather than `main.zig`
    // because the latter pulls in all of gooey (Metal, CoreText, AppKit) for
    // a test run that doesn't need any of it. Keeping the test module narrow
    // keeps `zig build test` under a second.

    const http_test_mod = b.createModule(.{
        .root_source_file = b.path("src/http.zig"),
        .target = target,
        .optimize = optimize,
    });

    // TLS on macOS still needs Security even for the test binary, because
    // `std.http` references it unconditionally via the module dependency.
    if (target.result.os.tag == .macos) {
        http_test_mod.linkFramework("Security", .{});
    }

    const http_tests = b.addTest(.{
        .name = "http-tests",
        .root_module = http_test_mod,
    });

    const run_http_tests = b.addRunArtifact(http_tests);

    // Same rationale as `http_test_mod`: narrow module, no gooey pulled in.
    const openai_test_mod = b.createModule(.{
        .root_source_file = b.path("src/openai.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .macos) {
        openai_test_mod.linkFramework("Security", .{});
    }

    const openai_tests = b.addTest(.{
        .name = "openai-tests",
        .root_module = openai_test_mod,
    });
    const run_openai_tests = b.addRunArtifact(openai_tests);

    const audio_test_mod = b.createModule(.{
        .root_source_file = b.path("src/audio/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .macos) {
        audio_test_mod.linkFramework("CoreAudio", .{});
        audio_test_mod.linkFramework("CoreFoundation", .{});
        audio_test_mod.linkFramework("AudioToolbox", .{});
    }

    const audio_tests = b.addTest(.{
        .name = "audio-tests",
        .root_module = audio_test_mod,
    });
    const run_audio_tests = b.addRunArtifact(audio_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_http_tests.step);
    test_step.dependOn(&run_openai_tests.step);
    test_step.dependOn(&run_audio_tests.step);
}
