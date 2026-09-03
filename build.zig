const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const onnxruntime_inc = b.option([]const u8, "onnxruntime-include",
        "OnnxRuntime include dir") orelse "/opt/homebrew/include/onnxruntime";
    const onnxruntime_lib = b.option([]const u8, "onnxruntime-lib",
        "OnnxRuntime lib dir")     orelse "/opt/homebrew/lib";

    const pq_inc = b.option([]const u8, "pq-include",
        "libpq include dir") orelse "/opt/homebrew/opt/postgresql@16/include";
    const pq_lib = b.option([]const u8, "pq-lib",
        "libpq lib dir")     orelse "/opt/homebrew/opt/postgresql@16/lib";

    // ── libkrul_core — daemon C layer (db + validate; NO onnxruntime) ─────
    const core_mod = b.createModule(.{
        .root_source_file = null,
        .target   = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_mod.addCSourceFiles(.{
        .files = &.{ "src/c/db.c", "src/c/validate.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    core_mod.addIncludePath(.{ .cwd_relative = pq_inc });
    core_mod.addIncludePath(.{ .cwd_relative = "src/c" });
    core_mod.addLibraryPath(.{ .cwd_relative = pq_lib });
    core_mod.linkSystemLibrary("pq", .{});

    const core_lib = b.addLibrary(.{
        .name       = "krul_core",
        .root_module = core_mod,
        .linkage    = .static,
    });
    b.installArtifact(core_lib);

    // ── kruld — daemon (Zig + libkrul_core; NO onnxruntime) ────────────
    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/main.zig"),
        .target   = target,
        .optimize = optimize,
        .link_libc = true,
    });
    daemon_mod.addIncludePath(.{ .cwd_relative = pq_inc });
    daemon_mod.addIncludePath(.{ .cwd_relative = "src/c" });
    daemon_mod.addLibraryPath(.{ .cwd_relative = pq_lib });
    daemon_mod.linkSystemLibrary("pq", .{});
    daemon_mod.linkLibrary(core_lib);

    const daemon = b.addExecutable(.{
        .name        = "kruld",
        .root_module = daemon_mod,
    });
    b.installArtifact(daemon);

    // ── krul — CLI client ──────────────────────────────────────────────────
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/cli.zig"),
        .target   = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const cli = b.addExecutable(.{
        .name        = "krul",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    // ── libkrul_ner — NER/ONNX C layer (plugin binary only) ───────────────
    const ner_mod = b.createModule(.{
        .root_source_file = null,
        .target   = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ner_mod.addCSourceFiles(.{
        .files = &.{ "src/c/infer.c", "src/c/tok.c", "src/c/index.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    ner_mod.addIncludePath(.{ .cwd_relative = onnxruntime_inc });
    ner_mod.addIncludePath(.{ .cwd_relative = "src/c" });
    ner_mod.addLibraryPath(.{ .cwd_relative = onnxruntime_lib });
    ner_mod.linkSystemLibrary("onnxruntime", .{});

    const ner_lib = b.addLibrary(.{
        .name        = "krul_ner",
        .root_module = ner_mod,
        .linkage     = .static,
    });

    // ── krul-indexer-codebert — built-in NER plugin binary ────────────────
    const plugin_mod = b.createModule(.{
        .root_source_file = null,
        .target   = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_mod.addCSourceFiles(.{
        .files = &.{ "src/c/plugin_main.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    plugin_mod.addIncludePath(.{ .cwd_relative = onnxruntime_inc });
    plugin_mod.addIncludePath(.{ .cwd_relative = "src/c" });
    plugin_mod.addLibraryPath(.{ .cwd_relative = onnxruntime_lib });
    plugin_mod.linkSystemLibrary("onnxruntime", .{});
    plugin_mod.linkLibrary(ner_lib);

    const plugin = b.addExecutable(.{
        .name        = "krul-indexer-codebert",
        .root_module = plugin_mod,
    });
    b.installArtifact(plugin);

    // ── test_infer — C smoke test for the NER layer ───────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = null,
        .target   = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addCSourceFiles(.{
        .files = &.{ "tests/test_infer.c" },
        .flags = &.{ "-std=c11", "-Wall" },
    });
    test_mod.addIncludePath(.{ .cwd_relative = onnxruntime_inc });
    test_mod.addIncludePath(.{ .cwd_relative = "src/c" });
    test_mod.addLibraryPath(.{ .cwd_relative = onnxruntime_lib });
    test_mod.linkSystemLibrary("onnxruntime", .{});
    test_mod.linkLibrary(ner_lib);

    const test_infer = b.addExecutable(.{
        .name        = "test_infer",
        .root_module = test_mod,
    });

    const run_test = b.addRunArtifact(test_infer);
    run_test.setCwd(b.path(".")); // so models/ resolves correctly

    const test_step = b.step("test", "Run C smoke tests");
    test_step.dependOn(&run_test.step);
}
