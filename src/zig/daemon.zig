const std = @import("std");
const net = std.Io.net;
const Dir = std.Io.Dir;
const c = @import("c.zig").lib;
const q = @import("queue.zig");
const ipc = @import("ipc.zig");
const llm = @import("llm.zig");
const config = @import("config.zig");
const gear_registry   = @import("gear_registry.zig");
const plugin_registry = @import("plugin_registry.zig");
const embedr          = @import("embed_runner.zig");

const log = std.log.scoped(.kruld);

pub fn cmd_start(io: std.Io) !void {
    const pid1 = std.c.fork();
    if (pid1 < 0) {
        log.err("fork() failed", .{});
        std.process.exit(1);
    }
    if (pid1 > 0) return;

    _ = std.c.setsid();

    const pid2 = std.c.fork();
    if (pid2 < 0) std.process.exit(1);
    if (pid2 > 0) std.process.exit(0);

    write_pidfile(io) catch |err| log.warn("could not write PID file: {}", .{err});

    q.g_db = c.krl_db_open(q.default_conninfo);
    if (q.g_db) |db| {
        if (c.krl_db_migrate(db) == 0) {
            log.info("postgresql connected ({s})", .{q.default_conninfo});
        } else {
            log.warn("postgresql migration failed — running without persistence", .{});
        }
        _ = c.krl_kanban_migrate(db);
    } else {
        log.warn("postgresql unavailable — task queue is in-memory only", .{});
    }

    // Load config first — embed server and LLM both need it.
    var cfg_buf: [4096]u8 = undefined;
    const cfg = config.load(&cfg_buf, "krul.toml") catch config.Config{};
    llm.init(io, cfg.llm_endpoint, cfg.llm_model, cfg.llm_api_key_env);

    gear_registry.loadAll(q.g_ally) catch |e|
        log.warn("gear loading failed: {}", .{e});
    plugin_registry.loadAll(q.g_ally) catch |e|
        log.warn("plugin loading failed: {}", .{e});

    // Start encoder server and pre-compute trigger embeddings.
    // Failures are non-fatal — tier-3 routing simply stays disabled.
    embedr.start(cfg.indexer_plugin, cfg.indexer_models_dir) catch |e|
        log.warn("encode-server not started: {}", .{e});
    gear_registry.loadEmbeddings(q.g_ally) catch |e|
        log.warn("trigger embedding failed: {}", .{e});

    log.info("kruld started (pid={})", .{std.c.getpid()});

    const executor_thread = try std.Thread.spawn(.{}, q.executor_loop, .{{}});
    executor_thread.detach();

    try run_daemon_loop(io);
}

fn write_pidfile(io: std.Io) !void {
    var f = try Dir.createFileAbsolute(io, q.pid_path, .{});
    defer f.close(io);
    var buf: [32]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.print("{d}\n", .{std.c.getpid()});
    try w.interface.flush();
}

fn run_daemon_loop(io: std.Io) !void {
    Dir.deleteFileAbsolute(io, q.sock_path) catch {};

    const unix_addr = try net.UnixAddress.init(q.sock_path);
    var server = try unix_addr.listen(io, .{});
    defer server.deinit(io);

    log.info("listening on {s}", .{q.sock_path});

    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);
        ipc.handle_connection(io, &stream) catch |err| {
            log.warn("connection error: {}", .{err});
        };
    }
}

pub fn cmd_stop(io: std.Io, ally: std.mem.Allocator) !void {
    const pid_str = Dir.cwd().readFileAlloc(io, q.pid_path, ally, .limited(64)) catch {
        log.err("no running daemon (no PID file found)", .{});
        std.process.exit(1);
    };
    defer ally.free(pid_str);

    const pid = try std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, pid_str, &std.ascii.whitespace), 10);
    try std.posix.kill(pid, std.posix.SIG.TERM);
    Dir.cwd().deleteFile(io, q.pid_path) catch {};
    log.info("sent SIGTERM to daemon (pid={})", .{pid});
}

pub fn cmd_status(io: std.Io, ally: std.mem.Allocator) !void {
    const pid_str = Dir.cwd().readFileAlloc(io, q.pid_path, ally, .limited(64)) catch {
        std.debug.print("kruld: not running\n", .{});
        return;
    };
    defer ally.free(pid_str);

    const pid = std.fmt.parseInt(std.c.pid_t,
        std.mem.trim(u8, pid_str, &std.ascii.whitespace), 10) catch {
        std.debug.print("kruld: corrupt PID file\n", .{});
        return;
    };

    std.posix.kill(pid, @enumFromInt(0)) catch {
        std.debug.print("kruld: stale PID (pid={d} not running)\n", .{pid});
        return;
    };

    const unix_addr = net.UnixAddress.init(q.sock_path) catch {
        std.debug.print("kruld: pid={d} running but address invalid\n", .{pid});
        return;
    };
    var stream = unix_addr.connect(io) catch {
        std.debug.print("kruld: pid={d} running but socket unreachable\n", .{pid});
        return;
    };
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("{\"method\":\"status\"}\n");
    try writer.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const resp = try reader.interface.takeDelimiterExclusive('\n');
    std.debug.print("kruld: pid={d} {s}\n", .{ pid, resp });
}
