const std = @import("std");

pub const Config = struct {
    // [indexer]
    indexer_plugin:     []const u8 = "krul-indexer-codebert",
    indexer_models_dir: []const u8 = "",

    // [db]
    db_conninfo: []const u8 = "dbname=krul host=localhost",

    // [daemon]
    daemon_socket:    []const u8 = "/tmp/krul.sock",
    daemon_log_level: []const u8 = "info",

    // [llm]
    llm_endpoint:    []const u8 = "",
    llm_model:       []const u8 = "",
    llm_api_key_env: []const u8 = "",
};

/// Load krul.toml from `path` (relative to cwd).  All string slices in the
/// returned Config point into `buf`, which the caller must keep alive.
/// Missing keys use Config defaults.  A missing file silently returns defaults.
pub fn load(buf: []u8, path: []const u8) !Config {
    // Use libc fopen so we don't need std.Io.
    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return Config{};
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const f = std.c.fopen(&path_z, "r") orelse return Config{};
    defer _ = std.c.fclose(f);
    const n = std.c.fread(buf.ptr, 1, buf.len, f);
    const content = buf[0..n];

    var cfg = Config{};
    var section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = line[1..end];
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));

        if (std.mem.eql(u8, section, "indexer")) {
            if (std.mem.eql(u8, key, "plugin"))     cfg.indexer_plugin     = val;
            if (std.mem.eql(u8, key, "models_dir")) cfg.indexer_models_dir = val;
        } else if (std.mem.eql(u8, section, "db")) {
            if (std.mem.eql(u8, key, "conninfo"))   cfg.db_conninfo        = val;
        } else if (std.mem.eql(u8, section, "daemon")) {
            if (std.mem.eql(u8, key, "socket"))     cfg.daemon_socket      = val;
            if (std.mem.eql(u8, key, "log_level"))  cfg.daemon_log_level   = val;
        } else if (std.mem.eql(u8, section, "llm")) {
            if (std.mem.eql(u8, key, "endpoint"))    cfg.llm_endpoint    = val;
            if (std.mem.eql(u8, key, "model"))        cfg.llm_model       = val;
            if (std.mem.eql(u8, key, "api_key_env")) cfg.llm_api_key_env = val;
        }
    }

    return cfg;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"')
        return s[1 .. s.len - 1];
    return s;
}
