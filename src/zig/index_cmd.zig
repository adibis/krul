const std    = @import("std");
const c      = @import("c.zig").lib;
const q      = @import("queue.zig");
const cfg    = @import("config.zig");
const runner = @import("plugin_runner.zig");

const log = std.log.scoped(.index);

pub fn cmd_index(ally: std.mem.Allocator, args: []const []const u8) !void {
    _ = args; // future: --incremental, --quiet flags

    // ── Load config ──────────────────────────────────────────────────────────
    var config_buf: [8192]u8 = undefined;
    const config = try cfg.load(&config_buf, "krul.toml");

    // ── Resolve plugin path ───────────────────────────────────────────────────
    const plugin_path = config.indexer_plugin;

    // ── Load ontology ─────────────────────────────────────────────────────────
    var ontology_path_z: [4096:0]u8 = undefined;
    {
        const olen = @min(config.ontology_path.len, ontology_path_z.len - 1);
        @memcpy(ontology_path_z[0..olen], config.ontology_path[0..olen]);
        ontology_path_z[olen] = 0;
    }
    var ontology: c.KrlOntology = undefined;
    if (c.krl_ontology_load(&ontology_path_z, &ontology) != 0) {
        log.err("cannot load ontology from {s}", .{config.ontology_path});
        std.process.exit(1);
    }

    // ── Split comma-separated indexer.search_dirs / indexer.file_extensions ────
    var search_dirs_buf: [16][]const u8 = undefined;
    var search_dirs_len: usize = 0;
    var sd_it = std.mem.splitScalar(u8, config.indexer_search_dirs, ',');
    while (sd_it.next()) |d| {
        if (d.len == 0 or search_dirs_len >= search_dirs_buf.len) continue;
        search_dirs_buf[search_dirs_len] = d;
        search_dirs_len += 1;
    }

    var extensions_buf: [16][]const u8 = undefined;
    var extensions_len: usize = 0;
    var ext_it = std.mem.splitScalar(u8, config.indexer_file_extensions, ',');
    while (ext_it.next()) |e| {
        if (e.len == 0 or extensions_len >= extensions_buf.len) continue;
        extensions_buf[extensions_len] = e;
        extensions_len += 1;
    }

    // ── Resolve models dir ────────────────────────────────────────────────────
    // Priority: config > KRUL_MODELS env > empty (plugin uses its own default)
    var models_dir = config.indexer_models_dir;
    if (models_dir.len == 0) {
        const env = std.c.getenv("KRUL_MODELS");
        if (env != null) models_dir = std.mem.sliceTo(env.?, 0);
    }

    // ── Connect to DB ─────────────────────────────────────────────────────────
    var conninfo_z: [512]u8 = undefined;
    const cilen = @min(config.db_conninfo.len, conninfo_z.len - 1);
    @memcpy(conninfo_z[0..cilen], config.db_conninfo[0..cilen]);
    conninfo_z[cilen] = 0;

    const db = c.krl_db_open(&conninfo_z) orelse {
        log.err("cannot connect to PostgreSQL ({s})", .{config.db_conninfo});
        std.process.exit(1);
    };
    defer c.krl_db_close(db);
    _ = c.krl_db_migrate(db);

    // ── Resolve project ───────────────────────────────────────────────────────
    var root_z: [4096]u8 = undefined;
    const got_cwd = std.c.getcwd(&root_z, root_z.len);
    if (got_cwd == null) {
        log.err("getcwd failed", .{});
        std.process.exit(1);
    }
    const root = std.mem.sliceTo(&root_z, 0);
    const proj_name = std.fs.path.basename(root);

    var proj_z: [256]u8 = undefined;
    const plen = @min(proj_name.len, proj_z.len - 1);
    @memcpy(proj_z[0..plen], proj_name[0..plen]);
    proj_z[plen] = 0;

    const project_id = c.krl_project_get_or_create(db, &proj_z, &root_z);
    if (project_id < 0) {
        log.err("cannot create project in DB", .{});
        std.process.exit(1);
    }

    log.info("project '{s}' (id={d}), plugin={s}", .{ proj_name, project_id, plugin_path });

    // ── Run plugin ────────────────────────────────────────────────────────────
    const stats = runner.run(
        ally, db, project_id, plugin_path, models_dir, root,
        &ontology, search_dirs_buf[0..search_dirs_len], extensions_buf[0..extensions_len],
    ) catch |err| {
        log.err("plugin runner failed: {}", .{err});
        std.process.exit(1);
    };

    std.debug.print(
        "indexed: {d} files, {d} entities, {d} relations, {d} errors\n",
        .{ stats.files, stats.entities, stats.relations, stats.errors },
    );
}
