// Kanban in-process capability plugin.
// Handles kanban.* IPC methods and the on_task_complete hook.

const std = @import("std");
const c = @import("../c.zig").lib;
const q = @import("../queue.zig");
const hooks = @import("../hooks.zig");

pub fn registerHooks() void {
    hooks.register("on_task_complete", onTaskComplete);
}

// Dispatch a kanban.* method call. Returns a JSON slice into out.
pub fn dispatch(method: []const u8, params: []const u8, out: []u8) []const u8 {
    const db = q.g_db orelse return err(out, "db not connected");

    if (std.mem.eql(u8, method, "kanban.add"))    return handleAdd(db, params, out);
    if (std.mem.eql(u8, method, "kanban.list"))   return handleList(db, params, out);
    if (std.mem.eql(u8, method, "kanban.get"))    return handleGet(db, params, out);
    if (std.mem.eql(u8, method, "kanban.update")) return handleMove(db, params, out);
    if (std.mem.eql(u8, method, "kanban.move"))   return handleMove(db, params, out);
    if (std.mem.eql(u8, method, "kanban.link"))   return handleLink(db, params, out);
    return err(out, "unknown kanban method");
}

fn handleAdd(db: *c.KrlDb, params: []const u8, out: []u8) []const u8 {
    const title = extractStr(params, "title") orelse return err(out, "title required");
    const body      = extractStr(params, "body");
    const gear_name = extractStr(params, "gear");
    const priority  = extractNum(params, "priority") orelse 50;

    var title_z:  [512:0]u8 = undefined;
    var body_z:   [4096:0]u8 = undefined;
    var gear_z:  [128:0]u8 = undefined;
    const title_p  = toZ(title, &title_z);
    const body_p   = if (body) |s| toZ(s, &body_z) else null;
    const gear_p  = if (gear_name) |s| toZ(s, &gear_z) else null;

    var task_id: [64]u8 = undefined;
    const rc = c.krl_kanban_add(db, title_p, body_p, gear_p,
                                 @intCast(priority), &task_id, task_id.len);
    if (rc != 0) return err(out, "db insert failed");
    const id_len = std.mem.indexOfScalar(u8, &task_id, 0) orelse task_id.len;
    return fmt(out, "{{\"task_id\":\"{s}\",\"status\":\"triage\"}}", .{task_id[0..id_len]});
}

fn handleList(db: *c.KrlDb, params: []const u8, out: []u8) []const u8 {
    const status = extractStr(params, "status");
    const limit  = extractNum(params, "limit") orelse 50;

    var status_z: [32:0]u8 = undefined;
    const status_p = if (status) |s| toZ(s, &status_z) else null;
    const rc = c.krl_kanban_list(db, status_p, @intCast(limit), out.ptr, out.len);
    if (rc != 0) return "[]";
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}

fn handleGet(db: *c.KrlDb, params: []const u8, out: []u8) []const u8 {
    const task_id = extractStr(params, "task_id") orelse
        extractStr(params, "id") orelse return err(out, "task_id required");
    var id_z: [64:0]u8 = undefined;
    _ = c.krl_kanban_get(db, toZ(task_id, &id_z), out.ptr, out.len);
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}

fn handleMove(db: *c.KrlDb, params: []const u8, out: []u8) []const u8 {
    const task_id  = extractStr(params, "task_id") orelse
        extractStr(params, "id") orelse return err(out, "task_id required");
    const new_status = extractStr(params, "status") orelse return err(out, "status required");
    var id_z:  [64:0]u8  = undefined;
    var st_z:  [32:0]u8  = undefined;
    _ = c.krl_kanban_move(db, toZ(task_id, &id_z), toZ(new_status, &st_z), out.ptr, out.len);
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}

fn handleLink(db: *c.KrlDb, params: []const u8, out: []u8) []const u8 {
    const parent = extractStr(params, "parent_id") orelse return err(out, "parent_id required");
    const child  = extractStr(params, "child_id")  orelse return err(out, "child_id required");
    var p_z: [64:0]u8 = undefined;
    var c_z: [64:0]u8 = undefined;
    const rc = c.krl_kanban_link(db, toZ(parent, &p_z), toZ(child, &c_z));
    if (rc != 0) return err(out, "link failed");
    return "{\"linked\":true}";
}

// on_task_complete hook: move any kanban card tracking this task queue entry to done/failed.
// Full wiring (krl_kanban_move per matching row) happens in Phase 4 when the executor
// sets gear_run_id on cards it creates.
fn onTaskComplete(payload: []const u8) void {
    const task_id  = extractNum(payload, "task_id")  orelse return;
    const exit_code = extractNum(payload, "exit_code") orelse 0;
    _ = task_id;
    _ = exit_code;
    // Phase 4: query kanban_tasks WHERE gear_run_id=task_id, call krl_kanban_move.
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn err(out: []u8, msg: []const u8) []const u8 {
    return fmt(out, "{{\"error\":\"{s}\"}}", .{msg});
}

fn fmt(out: []u8, comptime f: []const u8, args: anytype) []const u8 {
    const s = std.fmt.bufPrint(out, f, args) catch out[0..0];
    return s;
}

fn toZ(s: []const u8, buf: anytype) [*:0]const u8 {
    const l = @min(s.len, buf.len - 1);
    @memcpy(buf[0..l], s[0..l]);
    buf[l] = 0;
    return @ptrCast(buf);
}

fn extractStr(msg: []const u8, field: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{field}) catch return null;
    const start = (std.mem.indexOf(u8, msg, key) orelse return null) + key.len;
    const end = std.mem.indexOf(u8, msg[start..], "\"") orelse return null;
    return msg[start .. start + end];
}

fn extractNum(msg: []const u8, field: []const u8) ?i64 {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{field}) catch return null;
    const after = (std.mem.indexOf(u8, msg, key) orelse return null) + key.len;
    var i = after;
    while (i < msg.len and msg[i] == ' ') i += 1;
    const ns = i;
    while (i < msg.len and msg[i] >= '0' and msg[i] <= '9') i += 1;
    if (i == ns) return null;
    return std.fmt.parseInt(i64, msg[ns..i], 10) catch null;
}
