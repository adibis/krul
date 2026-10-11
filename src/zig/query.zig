// KB retrieval — thin wrappers around the entity/relation store in db.c.
// ipc.zig calls these; the underlying SQL functions are parameterised so
// any of the filter arguments can be null ("no filter").

const std = @import("std");
const c = @import("c.zig").lib;
const config = @import("config.zig");

// Phase 10 decay parameters, set once at daemon startup via initDecay().
// Defaults here match config.Config's own defaults, so a daemon that never
// calls initDecay() (e.g. a test harness exercising only the IPC layer)
// still gets sane evaporation behavior rather than zeroed-out thresholds.
pub const DecayConfig = struct {
    half_life_hours:      f64 = 720.0,
    strength_min:         f64 = 0.05,
    visibility_threshold: f64 = 0.1,
};

pub var g_decay: DecayConfig = .{};

pub fn initDecay(cfg: config.Config) void {
    g_decay = .{
        .half_life_hours      = cfg.decay_half_life_hours,
        .strength_min         = cfg.decay_strength_min,
        .visibility_threshold = cfg.decay_visibility_threshold,
    };
}

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
        g_decay.half_life_hours,
        g_decay.strength_min,
        g_decay.visibility_threshold,
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
        g_decay.half_life_hours,
        g_decay.strength_min,
        g_decay.visibility_threshold,
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
    const rc = c.krl_gothos_get_context(
        db,
        project_id,
        @ptrCast(&buf),
        depth,
        g_decay.half_life_hours,
        g_decay.strength_min,
        g_decay.visibility_threshold,
        out.ptr,
        out.len,
    );
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
    const rc = c.krl_gothos_no_covergroup(
        db,
        project_id,
        g_decay.half_life_hours,
        g_decay.strength_min,
        g_decay.visibility_threshold,
        out.ptr,
        out.len,
    );
    if (rc != 0) return error.QueryFailed;
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}

// reinforceEntity / reinforceRelation reset a row's strength to the
// ceiling and last_reinforced_at to now() — the only way strength moves
// back up; see PLAN.md Phase 10. Returns error.ReinforceFailed if id
// doesn't exist in the table.
//
// candidate_set_json, if given, is logged alongside the reinforcement
// (see krl_log_reinforcement) — the rest of what the caller was choosing
// from, needed for propensity correction later and unrecoverable if not
// captured now. A logging failure does not fail the reinforcement itself,
// which has already committed by the time logging runs.
pub fn reinforceEntity(db: *c.KrlDb, entity_id: i64, candidate_set_json: ?[]const u8) !void {
    if (c.krl_reinforce_entity(db, entity_id) != 0) return error.ReinforceFailed;
    logReinforcement(db, "entity", entity_id, candidate_set_json);
}

pub fn reinforceRelation(db: *c.KrlDb, relation_id: i64, candidate_set_json: ?[]const u8) !void {
    if (c.krl_reinforce_relation(db, relation_id) != 0) return error.ReinforceFailed;
    logReinforcement(db, "relation", relation_id, candidate_set_json);
}

const log = std.log.scoped(.query);

fn logReinforcement(db: *c.KrlDb, target_kind: [:0]const u8, target_id: i64, candidate_set_json: ?[]const u8) void {
    var buf: [8192:0]u8 = undefined;
    const c_candidates: ?[*:0]const u8 = if (candidate_set_json) |s| blk: {
        const l = @min(s.len, buf.len - 1);
        @memcpy(buf[0..l], s[0..l]);
        buf[l] = 0;
        break :blk @ptrCast(&buf);
    } else null;

    if (c.krl_log_reinforcement(db, target_kind, target_id, c_candidates) != 0)
        log.warn("failed to log reinforcement event (kind={s} id={d})", .{ target_kind, target_id });
}

// entityById writes one entity's full JSON record, bypassing the strength/
// visibility filter that entities() applies — a row excluded from default
// results is still reachable this way, by design (see PLAN.md Phase 10).
pub fn entityById(
    db: *c.KrlDb,
    entity_id: i64,
    out: []u8,
) ![]const u8 {
    const rc = c.krl_entity_get_by_id(db, entity_id, out.ptr, out.len);
    if (rc != 0) return error.NotFound;
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}
