const std = @import("std");

pub const Config = struct {
    // [indexer]
    indexer_plugin:         []const u8 = "krul-indexer-codebert",
    indexer_models_dir:     []const u8 = "",
    // Comma-separated. Defaults match the shipped DV/UVM plugin; a project
    // indexing a different domain overrides both to match its own file
    // layout rather than editing runner code.
    indexer_search_dirs:    []const u8 = "rtl,tb,dv,uvm,.",
    indexer_file_extensions: []const u8 = ".sv,.v,.svh,.uvm",

    // [ontology] — which kind/relation vocabulary indexed records are
    // checked against. DV/UVM is the shipped default so a fresh checkout
    // indexes chip-design projects with zero config, but any project can
    // point this at its own ontology file (see ontologies/stock-ta.json
    // for a second, unrelated example).
    ontology_path: []const u8 = "ontologies/dv-uvm.json",

    // [db]
    db_conninfo: []const u8 = "dbname=krul host=localhost",

    // [daemon]
    daemon_socket:    []const u8 = "/tmp/krul.sock",
    daemon_log_level: []const u8 = "info",

    // [llm]
    llm_endpoint:    []const u8 = "",
    llm_model:       []const u8 = "",
    llm_api_key_env: []const u8 = "",

    // [gates] — external policy script consulted before every `process`-type
    // gear stage runs. Krul's core has no opinion on what's safe to run; the
    // script is the entire policy, supplied by whoever configures krul for
    // this repo, same as gears and ontologies are project data, not core
    // logic. Empty path disables gating (every stage runs unconditionally).
    gate_process_script: []const u8 = "",

    // [decay] — Phase 10 evaporation-based invalidation (see PLAN.md Phase 10).
    // half_life_hours: time for an unreinforced row's strength to halve.
    // strength_min: read-time floor (the MAX-MIN Ant System bound) — strength
    //   can decay down to this value but never below, so a neglected row
    //   stays reachable by a future reinforcement event instead of decaying
    //   to something indistinguishable from zero.
    // visibility_threshold: default query.* results exclude rows whose
    //   current strength falls below this. Deliberately a separate knob from
    //   strength_min: collapsing the two into one value would mean either
    //   nothing is ever excluded, or excluded rows can never recover.
    decay_half_life_hours:      f64 = 720.0, // 30 days
    decay_strength_min:         f64 = 0.05,
    decay_visibility_threshold: f64 = 0.1,
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
            if (std.mem.eql(u8, key, "search_dirs"))     cfg.indexer_search_dirs     = val;
            if (std.mem.eql(u8, key, "file_extensions")) cfg.indexer_file_extensions = val;
        } else if (std.mem.eql(u8, section, "ontology")) {
            if (std.mem.eql(u8, key, "path"))       cfg.ontology_path      = val;
        } else if (std.mem.eql(u8, section, "db")) {
            if (std.mem.eql(u8, key, "conninfo"))   cfg.db_conninfo        = val;
        } else if (std.mem.eql(u8, section, "daemon")) {
            if (std.mem.eql(u8, key, "socket"))     cfg.daemon_socket      = val;
            if (std.mem.eql(u8, key, "log_level"))  cfg.daemon_log_level   = val;
        } else if (std.mem.eql(u8, section, "llm")) {
            if (std.mem.eql(u8, key, "endpoint"))    cfg.llm_endpoint    = val;
            if (std.mem.eql(u8, key, "model"))        cfg.llm_model       = val;
            if (std.mem.eql(u8, key, "api_key_env")) cfg.llm_api_key_env = val;
        } else if (std.mem.eql(u8, section, "gates")) {
            if (std.mem.eql(u8, key, "process_script")) cfg.gate_process_script = val;
        } else if (std.mem.eql(u8, section, "decay")) {
            if (std.mem.eql(u8, key, "half_life_hours")) {
                cfg.decay_half_life_hours = std.fmt.parseFloat(f64, val) catch cfg.decay_half_life_hours;
            } else if (std.mem.eql(u8, key, "strength_min")) {
                cfg.decay_strength_min = std.fmt.parseFloat(f64, val) catch cfg.decay_strength_min;
            } else if (std.mem.eql(u8, key, "visibility_threshold")) {
                cfg.decay_visibility_threshold = std.fmt.parseFloat(f64, val) catch cfg.decay_visibility_threshold;
            }
        }
    }

    return cfg;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"')
        return s[1 .. s.len - 1];
    return s;
}

// Writes `contents` to `path` via plain libc, mirroring load()'s own
// fopen-based I/O so these tests don't depend on std.Io's Dir/tmpDir API
// (which changes shape across zig versions independently of config.zig's
// own on-disk format).
fn writeTempConfig(path: [:0]const u8, contents: []const u8) !void {
    const f = std.c.fopen(path, "w") orelse return error.OpenFailed;
    defer _ = std.c.fclose(f);
    const n = std.c.fwrite(contents.ptr, 1, contents.len, f);
    if (n != contents.len) return error.WriteFailed;
}

test "decay config defaults when the file or [decay] section is absent" {
    var buf: [4096]u8 = undefined;
    const cfg = try load(&buf, "/nonexistent/path/krul.toml");
    try std.testing.expectEqual(@as(f64, 720.0), cfg.decay_half_life_hours);
    try std.testing.expectEqual(@as(f64, 0.05), cfg.decay_strength_min);
    try std.testing.expectEqual(@as(f64, 0.1), cfg.decay_visibility_threshold);
}

test "decay config parses explicit [decay] values" {
    const path = "/tmp/krul_config_test_explicit.toml";
    try writeTempConfig(path,
        "[decay]\nhalf_life_hours = 48.5\nstrength_min = 0.02\nvisibility_threshold = 0.15\n");

    var buf: [4096]u8 = undefined;
    const cfg = try load(&buf, path);
    try std.testing.expectApproxEqAbs(@as(f64, 48.5), cfg.decay_half_life_hours, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), cfg.decay_strength_min, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), cfg.decay_visibility_threshold, 1e-9);
}

test "decay config keeps its default when a value fails to parse" {
    const path = "/tmp/krul_config_test_badvalue.toml";
    try writeTempConfig(path, "[decay]\nhalf_life_hours = not_a_number\n");

    var buf: [4096]u8 = undefined;
    const cfg = try load(&buf, path);
    try std.testing.expectEqual(@as(f64, 720.0), cfg.decay_half_life_hours);
}

test "decay config does not leak values from unrelated sections" {
    const path = "/tmp/krul_config_test_sections.toml";
    try writeTempConfig(path,
        "[daemon]\nsocket = \"/tmp/other.sock\"\n[decay]\nstrength_min = 0.2\n");

    var buf: [4096]u8 = undefined;
    const cfg = try load(&buf, path);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), cfg.decay_strength_min, 1e-9);
    try std.testing.expectEqual(@as(f64, 720.0), cfg.decay_half_life_hours);
}
