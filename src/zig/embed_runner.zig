// Long-running encoder subprocess for tier-3 router embedding.
//
// Spawns krul-indexer-codebert with --encode-server once at daemon startup.
// The process stays alive for the daemon's lifetime: the daemon writes one text
// line per encoding request and reads one {"embed":[...768 floats...]} line back.
// No per-query subprocess overhead — ONNX is loaded once.
//
// Only safe to call from the single-threaded IPC loop.

const std = @import("std");

const EMBED_DIM = 768;

// execvp is POSIX but not wrapped by std.c in 0.16
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const log = std.log.scoped(.embed);

var g_pid:       std.c.pid_t  = 0;
var g_write_fd:  std.c.fd_t   = -1;
var g_read_fd:   std.c.fd_t   = -1;

// Buffered reader state for the subprocess stdout pipe.
var g_rbuf:  [16384]u8 = undefined; // 16 KB — enough for 768 floats as JSON
var g_rfill: usize     = 0;
var g_rpos:  usize     = 0;

pub fn isRunning() bool { return g_pid > 0; }

// start spawns the plugin in --encode-server mode.
// plugin_path: path to krul-indexer-codebert binary.
// models_dir:  path to the models directory (may be empty to use default).
// Fails silently if models_dir is empty or the binary cannot be found —
// the router falls back to .embedding_needed in that case.
pub fn start(plugin_path: []const u8, models_dir: []const u8) !void {
    if (g_pid > 0) return; // already running

    var plugin_z: [4096:0]u8 = undefined;
    const plen = @min(plugin_path.len, plugin_z.len - 1);
    @memcpy(plugin_z[0..plen], plugin_path[0..plen]);
    plugin_z[plen] = 0;

    var flag_z = "--encode-server".*;
    var models_z: [4096:0]u8 = undefined;
    const mlen = @min(models_dir.len, models_z.len - 1);
    @memcpy(models_z[0..mlen], models_dir[0..mlen]);
    models_z[mlen] = 0;

    var stdin_pipe:  [2]std.c.fd_t = undefined;
    var stdout_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&stdin_pipe)  != 0) return error.PipeFailed;
    if (std.c.pipe(&stdout_pipe) != 0) {
        _ = std.c.close(stdin_pipe[0]); _ = std.c.close(stdin_pipe[1]);
        return error.PipeFailed;
    }

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(stdin_pipe[0]);  _ = std.c.close(stdin_pipe[1]);
        _ = std.c.close(stdout_pipe[0]); _ = std.c.close(stdout_pipe[1]);
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = std.c.dup2(stdin_pipe[0],  std.c.STDIN_FILENO);
        _ = std.c.dup2(stdout_pipe[1], std.c.STDOUT_FILENO);
        _ = std.c.close(stdin_pipe[0]);  _ = std.c.close(stdin_pipe[1]);
        _ = std.c.close(stdout_pipe[0]); _ = std.c.close(stdout_pipe[1]);

        const argv: [*:null]const ?[*:0]const u8 =
            if (mlen > 0)
                &[_:null]?[*:0]const u8{ &plugin_z, @ptrCast(&flag_z), &models_z, null }
            else
                &[_:null]?[*:0]const u8{ &plugin_z, @ptrCast(&flag_z), null };

        _ = execvp(&plugin_z, argv);
        std.c._exit(1);
    }

    _ = std.c.close(stdin_pipe[0]);
    _ = std.c.close(stdout_pipe[1]);

    g_pid      = pid;
    g_write_fd = stdin_pipe[1];
    g_read_fd  = stdout_pipe[0];
    g_rfill    = 0;
    g_rpos     = 0;

    log.info("encode-server started (pid={d})", .{pid});
}

// stop closes the write pipe (signalling EOF to the subprocess) and reaps it.
pub fn stop() void {
    if (g_pid <= 0) return;
    _ = std.c.close(g_write_fd);
    _ = std.c.close(g_read_fd);
    var ws: c_int = 0;
    _ = std.c.waitpid(g_pid, &ws, 0);
    log.info("encode-server stopped (pid={d})", .{g_pid});
    g_pid = 0; g_write_fd = -1; g_read_fd = -1;
}

// encode sends text to the encode-server subprocess and parses the 768-dim
// float response into out_embed.  Returns error if the subprocess died or
// returned {"embed":null}.
pub fn encode(text: []const u8, out_embed: *[EMBED_DIM]f32) !void {
    if (g_pid <= 0) return error.NotRunning;

    // Write "text\n" to subprocess stdin.
    var written: usize = 0;
    while (written < text.len) {
        const n = std.c.write(g_write_fd, text[written..].ptr, text.len - written);
        if (n <= 0) { markDead(); return error.SubprocessDied; }
        written += @intCast(n);
    }
    const nl: [1]u8 = .{'\n'};
    if (std.c.write(g_write_fd, &nl, 1) <= 0) { markDead(); return error.SubprocessDied; }

    // Read one response line from subprocess stdout.
    const line = readLine() orelse { markDead(); return error.SubprocessDied; };

    // Parse {"embed":[f0,f1,...,f767]} or {"embed":null}
    try parseEmbed(line, out_embed);
}

// ── Internal helpers ─────────────────────────────────────────────────────────

fn markDead() void {
    _ = std.c.close(g_write_fd);
    _ = std.c.close(g_read_fd);
    var ws: c_int = 0;
    _ = std.c.waitpid(g_pid, &ws, 0);
    g_pid = 0; g_write_fd = -1; g_read_fd = -1;
    log.warn("encode-server process died", .{});
}

// readLine returns a slice into g_rbuf ending just before the newline.
// Returns null if the subprocess closed stdout.
fn readLine() ?[]const u8 {
    while (true) {
        // Scan buffered bytes for a newline.
        const buffered = g_rbuf[g_rpos..g_rfill];
        if (std.mem.indexOfScalar(u8, buffered, '\n')) |nl_off| {
            const line = g_rbuf[g_rpos .. g_rpos + nl_off];
            g_rpos += nl_off + 1;
            return line;
        }

        // No newline yet — compact and refill.
        if (g_rpos > 0) {
            const remaining = g_rfill - g_rpos;
            std.mem.copyForwards(u8, g_rbuf[0..remaining], g_rbuf[g_rpos..g_rfill]);
            g_rfill = remaining;
            g_rpos  = 0;
        }
        if (g_rfill >= g_rbuf.len) return null; // line too long

        const n = std.c.read(g_read_fd, g_rbuf[g_rfill..].ptr, g_rbuf.len - g_rfill);
        if (n <= 0) return null;
        g_rfill += @intCast(n);
    }
}

// parseEmbed scans {"embed":[f0,...,f767]} and fills out_embed.
fn parseEmbed(line: []const u8, out: *[EMBED_DIM]f32) !void {
    // Quick null check before scanning.
    if (std.mem.indexOf(u8, line, "null") != null) return error.NullEmbed;

    const bracket = std.mem.indexOfScalar(u8, line, '[') orelse return error.BadFormat;
    var pos: usize = bracket + 1;
    var idx: usize = 0;

    while (idx < EMBED_DIM and pos < line.len) {
        // Skip whitespace and commas.
        while (pos < line.len and (line[pos] == ',' or line[pos] == ' ')) pos += 1;
        if (pos >= line.len or line[pos] == ']') break;

        // Find end of this number token (next comma, ']', or end of string).
        const tok_start = pos;
        while (pos < line.len and line[pos] != ',' and line[pos] != ']') pos += 1;
        const token = line[tok_start..pos];
        out[idx] = std.fmt.parseFloat(f32, token) catch return error.BadFloat;
        idx += 1;
    }

    if (idx != EMBED_DIM) return error.WrongDim;
}
