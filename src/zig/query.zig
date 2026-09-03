// KB retrieval — thin wrappers around the entity/relation store in db.c.
// ipc.zig calls these; the underlying SQL functions are parameterised so
// any of the filter arguments can be null ("no filter").

const std = @import("std");
const c = @import("c.zig").lib;

// Resolve a project name to its id. Returns 1 (first project) when name is
// null or not found — callers that need strict isolation should check for -1.
pub fn resolveProject(db: *c.KrlDb, name: ?[]const u8) i64 {
    const n = name orelse return 1;
    var z: [256:0]u8 = undefined;
    const l = @min(n.len, 255);
    @memcpy(z[0..l], n[0..l]);
    z[l] = 0;
    const id = c.krl_project_lookup(db, @ptrCast(&z));
    return if (id > 0) id else 1;
}

// Copy an optional slice into a stack buffer, returning a nullable C string.
fn toZopt(src: ?[]const u8, buf: []u8) ?[*:0]const u8 {
    const s = src orelse return null;
    const l = @min(s.len, buf.len - 1);
    @memcpy(buf[0..l], s[0..l]);
    buf[l] = 0;
    return @ptrCast(buf.ptr);
}

// entities writes a JSON array of matching entities into out.
// kind and name_pattern are optional SQL ILIKE filters.
pub fn entities(
    db: *c.KrlDb,
    project_id: i64,
    kind: ?[]const u8,
    name_pattern: ?[]const u8,
    out: []u8,
) ![]const u8 {
    var kind_buf: [64]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    const rc = c.krl_gothos_query_entities(
        db,
        project_id,
        toZopt(kind, &kind_buf),
        toZopt(name_pattern, &name_buf),
        out.ptr,
        out.len,
    );
    if (rc != 0) return error.QueryFailed;
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}

// relations writes a JSON array of matching edges into out.
// from_name and rel_kind are optional filters; both null returns all relations.
pub fn relations(
    db: *c.KrlDb,
    project_id: i64,
    from_name: ?[]const u8,
    rel_kind: ?[]const u8,
    out: []u8,
) ![]const u8 {
    var from_buf: [256]u8 = undefined;
    var kind_buf: [64]u8 = undefined;
    const rc = c.krl_gothos_query_relations(
        db,
        project_id,
        toZopt(from_name, &from_buf),
        toZopt(rel_kind, &kind_buf),
        out.ptr,
        out.len,
    );
    if (rc != 0) return error.QueryFailed;
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}

// context writes {"entities":[...],"relations":[...]} centred on focus_name.
// depth is accepted but only depth=1 (direct neighbours) is active.
pub fn context(
    db: *c.KrlDb,
    project_id: i64,
    focus_name: []const u8,
    depth: i32,
    out: []u8,
) ![]const u8 {
    var buf: [256:0]u8 = undefined;
    const l = @min(focus_name.len, 255);
    @memcpy(buf[0..l], focus_name[0..l]);
    buf[l] = 0;
    const rc = c.krl_gothos_get_context(db, project_id, @ptrCast(&buf), depth, out.ptr, out.len);
    if (rc != 0) return error.QueryFailed;
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}

// noCovergroup writes a JSON array of UVM_AGENT entities with no
// HAS_COVERGROUP edge — deterministic structural coverage gap query.
pub fn noCovergroup(
    db: *c.KrlDb,
    project_id: i64,
    out: []u8,
) ![]const u8 {
    const rc = c.krl_gothos_no_covergroup(db, project_id, out.ptr, out.len);
    if (rc != 0) return error.QueryFailed;
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}
