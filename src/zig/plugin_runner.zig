/// Plugin subprocess runner — core of the krul indexing pipeline.
///
/// Spawns the configured indexer plugin binary, feeds absolute file paths to
/// its stdin (one per line), reads NDJSON entity/relation records from its
/// stdout, validates each record, and inserts valid ones into PostgreSQL.
///
/// Plugin protocol (stdin → stdout):
///   stdin  : newline-delimited absolute file paths; closed when list is done
///   stdout : newline-delimited JSON records (plugin_schema.json)
///   stderr : forwarded to our stderr; treated as diagnostics only

const std = @import("std");
const c   = @import("c.zig").lib;

const log = std.log.scoped(.plugin);

// execvp is POSIX but not wrapped by std.c in 0.16
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub const Stats = struct {
    files:     u32 = 0,
    entities:  u32 = 0,
    relations: u32 = 0,
    errors:    u32 = 0,
};

const SV_EXTS      = [_][]const u8{ ".sv", ".v", ".svh", ".uvm" };
const DEFAULT_DIRS = [_][]const u8{ "rtl", "tb", "dv", "uvm", "." };

pub fn run(
    ally:        std.mem.Allocator,
    db:          *c.KrlDb,
    project_id:  i64,
    plugin_path: []const u8,
    models_dir:  []const u8,
    root:        []const u8,
) !Stats {
    // ── Collect SV/V/SVH/UVM files ──────────────────────────────────────────
    var files: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (files.items) |f| ally.free(f);
        files.deinit(ally);
    }

    for (DEFAULT_DIRS) |sub| {
        const dir_path = std.fmt.allocPrint(ally, "{s}/{s}", .{ root, sub }) catch continue;
        defer ally.free(dir_path);
        collectSvFiles(ally, dir_path, &files) catch {};
    }

    if (files.items.len == 0) {
        log.info("no SV files found under {s}", .{root});
        return Stats{};
    }

    // ── Delete stale entities for all files before the run ──────────────────
    for (files.items) |path| {
        var path_z: [4096:0]u8 = undefined;
        const plen = @min(path.len, path_z.len - 1);
        @memcpy(path_z[0..plen], path[0..plen]);
        path_z[plen] = 0;
        _ = c.krl_entities_delete_file(db, project_id, &path_z);
    }

    // ── Null-terminate plugin path and models_dir ────────────────────────────
    var plugin_z: [4096:0]u8 = undefined;
    {
        const plen = @min(plugin_path.len, plugin_z.len - 1);
        @memcpy(plugin_z[0..plen], plugin_path[0..plen]);
        plugin_z[plen] = 0;
    }
    var models_z: [4096:0]u8 = undefined;
    {
        const mlen = @min(models_dir.len, models_z.len - 1);
        @memcpy(models_z[0..mlen], models_dir[0..mlen]);
        models_z[mlen] = 0;
    }

    // ── Set up pipes ─────────────────────────────────────────────────────────
    var stdin_pipe:  [2]std.c.fd_t = undefined;
    var stdout_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&stdin_pipe)  != 0) return error.PipeFailed;
    if (std.c.pipe(&stdout_pipe) != 0) {
        _ = std.c.close(stdin_pipe[0]);
        _ = std.c.close(stdin_pipe[1]);
        return error.PipeFailed;
    }

    // ── Fork ──────────────────────────────────────────────────────────────────
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // Child: wire pipes and exec plugin
        _ = std.c.dup2(stdin_pipe[0],  std.c.STDIN_FILENO);
        _ = std.c.dup2(stdout_pipe[1], std.c.STDOUT_FILENO);
        _ = std.c.close(stdin_pipe[0]);
        _ = std.c.close(stdin_pipe[1]);
        _ = std.c.close(stdout_pipe[0]);
        _ = std.c.close(stdout_pipe[1]);

        const argv: [*:null]const ?[*:0]const u8 = if (models_dir.len > 0)
            &[_:null]?[*:0]const u8{ &plugin_z, &models_z, null }
        else
            &[_:null]?[*:0]const u8{ &plugin_z, null };

        _ = execvp(&plugin_z, argv);
        std.c._exit(1);
    }

    // Parent: close child ends of pipes
    _ = std.c.close(stdin_pipe[0]);
    _ = std.c.close(stdout_pipe[1]);

    const write_fd = stdin_pipe[1];
    const read_fd  = stdout_pipe[0];

    log.info("spawned {s} (pid={d}) for {d} files", .{ plugin_path, pid, files.items.len });

    // ── Write file paths to stdin in a background thread ─────────────────────
    const WriteCtx = struct { fd: std.c.fd_t, files: []const []u8 };
    const wctx = WriteCtx{ .fd = write_fd, .files = files.items };
    const writer_thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: WriteCtx) void {
            defer _ = std.c.close(ctx.fd);
            for (ctx.files) |path| {
                _ = std.c.write(ctx.fd, path.ptr, path.len);
                _ = std.c.write(ctx.fd, "\n", 1);
            }
        }
    }.run, .{wctx});

    // ── Read stdout line by line, validate, ingest ────────────────────────────
    var stats = Stats{ .files = @intCast(files.items.len) };
    var line_buf: [65536]u8 = undefined;
    var line_len: usize = 0;
    var read_tmp: [8192]u8 = undefined;
    var line_no: i32 = 0;

    while (true) {
        const n = std.c.read(read_fd, &read_tmp, read_tmp.len);
        if (n <= 0) break;

        for (read_tmp[0..@intCast(n)]) |byte| {
            if (byte == '\n') {
                if (line_len > 0) {
                    line_no += 1;
                    line_buf[line_len] = 0;
                    processLine(&stats, db, project_id, line_buf[0..line_len], line_no);
                }
                line_len = 0;
            } else if (line_len < line_buf.len - 1) {
                line_buf[line_len] = byte;
                line_len += 1;
            }
        }
    }
    // Flush any trailing partial line (plugin closed stdout without final newline)
    if (line_len > 0) {
        line_no += 1;
        line_buf[line_len] = 0;
        processLine(&stats, db, project_id, line_buf[0..line_len], line_no);
    }

    _ = std.c.close(read_fd);
    writer_thread.join();

    // Reap child
    var wstatus: c_int = 0;
    _ = std.c.waitpid(pid, &wstatus, 0);
    const code = std.c.W.EXITSTATUS(@bitCast(wstatus));
    if (code != 0) {
        log.warn("plugin exited with code {d}", .{code});
    }

    log.info("done: {d} entities, {d} relations, {d} errors",
             .{ stats.entities, stats.relations, stats.errors });
    return stats;
}

fn processLine(stats: *Stats, db: *c.KrlDb, project_id: i64,
               line: []u8, line_no: i32) void {
    if (line[0] == '#') return; // comment line from plugin

    var verr: c.KrlValidateError = std.mem.zeroes(c.KrlValidateError);
    if (c.krl_validate_record(line.ptr, line_no, &verr) != 0) {
        log.warn("line {d} invalid: {s}", .{ line_no, std.mem.sliceTo(&verr.message, 0) });
        stats.errors += 1;
        return;
    }

    if (c.krl_ingest_record(db, project_id, line.ptr) == 0) {
        if (std.mem.indexOf(u8, line, "\"entity\"") != null) {
            stats.entities += 1;
        } else {
            stats.relations += 1;
        }
    } else {
        stats.errors += 1;
    }
}

// ── Directory walker ─────────────────────────────────────────────────────────

fn collectSvFiles(ally: std.mem.Allocator, dir_path: []const u8,
                  out: *std.ArrayListUnmanaged([]u8)) !void {
    var dir_z: [4096:0]u8 = undefined;
    const dlen = @min(dir_path.len, dir_z.len - 1);
    @memcpy(dir_z[0..dlen], dir_path[0..dlen]);
    dir_z[dlen] = 0;

    const dir = std.c.opendir(&dir_z) orelse return;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(&ent.name, 0);
        if (name[0] == '.') continue; // skip hidden / . / ..

        const dt = ent.type;
        if (dt == std.c.DT.DIR) {
            const full = try std.fmt.allocPrint(ally, "{s}/{s}", .{ dir_path, name });
            defer ally.free(full);
            collectSvFiles(ally, full, out) catch {};
        } else if (dt == std.c.DT.REG and isSvFile(name)) {
            const full = try std.fmt.allocPrint(ally, "{s}/{s}", .{ dir_path, name });
            try out.append(ally, full);
        }
    }
}

fn isSvFile(name: []const u8) bool {
    for (SV_EXTS) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}
