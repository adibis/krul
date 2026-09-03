// Plugin registry — parses plugin.yaml manifests and dispatches IPC calls to
// in-process capability plugins. External process plugins are Phase 10.

const std = @import("std");
const hooks = @import("hooks.zig");
const kanban = @import("plugins/kanban.zig");

const log = std.log.scoped(.plugins);

pub const PluginKind = enum { extractor, capability };

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    kind: PluginKind,
    // capability plugins only
    provides_methods: []const []const u8,
    provides_hooks: []const []const u8,
    // extractor plugins only
    emits_kinds: []const []const u8,
    emits_relations: []const []const u8,
    _arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Manifest) void { self._arena.deinit(); }
};

// In-process capability plugin dispatch table entry.
const InProcessPlugin = struct {
    method_prefix: []const u8,
    dispatch: *const fn (method: []const u8, params: []const u8, out: []u8) []const u8,
};

const builtin_plugins = [_]InProcessPlugin{
    .{ .method_prefix = "kanban.", .dispatch = kanban.dispatch },
};

var g_manifests: std.ArrayListUnmanaged(Manifest) = .empty;

pub fn loadAll(ally: std.mem.Allocator) !void {
    // Scan standard plugin directories.
    if (std.c.getenv("KRUL_PLUGINS")) |env|
        try loadDir(ally, std.mem.sliceTo(env, 0));
    try loadDir(ally, "plugins");
    if (std.c.getenv("HOME")) |h| {
        const home = std.mem.sliceTo(h, 0);
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/.krul/plugins", .{home}) catch "";
        if (p.len > 0) try loadDir(ally, p);
    }

    // Register hooks declared by built-in capability plugins.
    kanban.registerHooks();

    log.info("{d} plugin manifest(s) loaded", .{g_manifests.items.len});
}

// Route an IPC method call to the matching in-process capability plugin.
// Returns null if no plugin handles this method.
pub fn routeMethod(method: []const u8, params: []const u8, out: []u8) ?[]const u8 {
    for (builtin_plugins) |p| {
        if (std.mem.startsWith(u8, method, p.method_prefix))
            return p.dispatch(method, params, out);
    }
    return null;
}

fn loadDir(ally: std.mem.Allocator, dir_path: []const u8) !void {
    var dir_z: [4096:0]u8 = undefined;
    if (dir_path.len >= dir_z.len) return;
    @memcpy(dir_z[0..dir_path.len], dir_path);
    dir_z[dir_path.len] = 0;

    const dir = std.c.opendir(&dir_z) orelse return;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |ent| {
        if (ent.type != std.c.DT.DIR) continue;
        const ename = std.mem.sliceTo(&ent.name, 0);
        if (ename[0] == '.') continue;

        var yaml_path: [4096]u8 = undefined;
        const yp = std.fmt.bufPrint(&yaml_path,
            "{s}/{s}/plugin.yaml", .{ dir_path, ename }) catch continue;

        const m = loadManifest(ally, yp) catch |err| {
            log.warn("skipping plugin {s}: {}", .{ ename, err });
            continue;
        };
        try g_manifests.append(ally, m);
        log.info("plugin '{s}' ({s})", .{ m.name, @tagName(m.kind) });
    }
}

fn loadManifest(backing_ally: std.mem.Allocator, path: []const u8) !Manifest {
    var arena = std.heap.ArenaAllocator.init(backing_ally);
    errdefer arena.deinit();
    const ally = arena.allocator();

    var path_z: [4096:0]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const f = std.c.fopen(&path_z, "r") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    var raw: [16384]u8 = undefined;
    const n = std.c.fread(raw[0..].ptr, 1, raw.len - 1, f);
    raw[n] = 0;

    var m = Manifest{
        .name = "", .version = "0.0.0",
        .kind = .extractor,
        .provides_methods = &.{}, .provides_hooks = &.{},
        .emits_kinds = &.{}, .emits_relations = &.{},
        ._arena = arena,
    };

    var cur_list: ?*std.ArrayListUnmanaged([]const u8) = null;
    var methods: std.ArrayListUnmanaged([]const u8) = .empty;
    var hook_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var kinds: std.ArrayListUnmanaged([]const u8) = .empty;
    var relations: std.ArrayListUnmanaged([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, raw[0..n], '\n');
    while (lines.next()) |raw_line| {
        var indent: usize = 0;
        while (indent < raw_line.len and raw_line[indent] == ' ') indent += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (indent == 0) {
            cur_list = null;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = line[0..colon];
            const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (val.len == 0) {
                if (std.mem.eql(u8, key, "provides_methods")) cur_list = &methods;
                if (std.mem.eql(u8, key, "provides_hooks"))   cur_list = &hook_list;
                if (std.mem.eql(u8, key, "emits_kinds"))      cur_list = &kinds;
                if (std.mem.eql(u8, key, "emits_relations"))  cur_list = &relations;
            } else {
                if (std.mem.eql(u8, key, "name"))    m.name    = try ally.dupe(u8, val);
                if (std.mem.eql(u8, key, "version")) m.version = try ally.dupe(u8, val);
                if (std.mem.eql(u8, key, "kind")) {
                    if (std.mem.eql(u8, val, "capability")) m.kind = .capability;
                }
            }
        } else if (indent == 2 and line[0] == '-') {
            const item = std.mem.trim(u8, line[1..], " \t");
            if (cur_list) |lst| try lst.append(ally, try ally.dupe(u8, item));
        }
    }

    m.provides_methods = try methods.toOwnedSlice(ally);
    m.provides_hooks   = try hook_list.toOwnedSlice(ally);
    m.emits_kinds      = try kinds.toOwnedSlice(ally);
    m.emits_relations  = try relations.toOwnedSlice(ally);
    return m;
}
