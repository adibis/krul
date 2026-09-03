const std = @import("std");
const net = std.Io.net;
const c = @import("c.zig").lib;
const q = @import("queue.zig");
const kb = @import("query.zig");
const llm      = @import("llm.zig");
const executor = @import("executor.zig");
const plugins  = @import("plugin_registry.zig");
const gears    = @import("gear_registry.zig");
const router   = @import("router.zig");

const log = std.log.scoped(.ipc);

// Module-level buffers so dispatch can safely return slices to its caller.
// Single-threaded accept loop — no concurrent access.
var g_resp_buf: [72000]u8 = undefined; // wrapper: "{"result":...}"
var g_data_buf: [65536]u8 = undefined; // kb retrieval output

pub fn handle_connection(io: std.Io, stream: *net.Stream) !void {
    var read_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    var write_buf: [8192]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    const msg = try reader.interface.takeDelimiterExclusive('\n');
    const trimmed = std.mem.trim(u8, msg, &std.ascii.whitespace);

    const response = dispatch(trimmed) catch |err| blk: {
        const s = std.fmt.bufPrint(&g_resp_buf, "{{\"error\":\"{}\"}}", .{err}) catch
            "{\"error\":\"internal\"}";
        break :blk s;
    };

    try writer.interface.writeAll(response);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

fn dispatch(msg: []const u8) ![]const u8 {
    if (matchMethod(msg, "ping")) {
        return "{\"result\":\"pong\"}";
    }

    if (matchMethod(msg, "status")) {
        q.mu_lock();
        var pending: usize = 0;
        var running: usize = 0;
        for (q.g_tasks.items) |t| {
            if (t.state == .pending) pending += 1;
            if (t.state == .running) running += 1;
        }
        const total = q.g_tasks.items.len;
        q.mu_unlock();
        return std.fmt.bufPrint(&g_resp_buf,
            "{{\"result\":{{\"state\":\"running\",\"tasks\":{{\"total\":{d},\"pending\":{d},\"running\":{d}}}}}}}",
            .{ total, pending, running },
        ) catch return "{\"error\":\"buf overflow\"}";
    }

    if (matchMethod(msg, "task.submit")) {
        const cmd = extractString(msg, "cmd") orelse
            return "{\"error\":\"missing cmd\"}";
        const kind_str = extractString(msg, "kind") orelse "shell";
        const kind: q.TaskKind = if (std.mem.eql(u8, kind_str, "index")) .index
                             else if (std.mem.eql(u8, kind_str, "triage")) .triage
                             else .shell;

        const cmd_owned = try q.g_ally.dupe(u8, cmd);

        q.mu_lock();
        const id = q.g_next_id;
        q.g_next_id += 1;
        try q.g_tasks.append(q.g_ally, .{
            .id           = id,
            .kind         = kind,
            .state        = .pending,
            .cmd          = cmd_owned,
            .exit_code    = 0,
            .stdout_tail  = undefined,
            .stdout_len   = 0,
            .created_ns   = q.nanoTimestamp(),
            .completed_ns = 0,
        });
        q.mu_unlock();

        if (q.g_db) |db| {
            var kind_z: [16]u8 = undefined;
            const klen = @min(kind_str.len, kind_z.len - 1);
            @memcpy(kind_z[0..klen], kind_str[0..klen]);
            kind_z[klen] = 0;

            var params_json: [512]u8 = undefined;
            const pslice = std.fmt.bufPrint(params_json[0..511], "{{\"cmd\":\"{s}\"}}", .{cmd}) catch params_json[0..0];
            params_json[pslice.len] = 0;

            var db_id: i64 = 0;
            _ = c.krl_task_insert(db, &kind_z, &params_json, &db_id);
        }

        log.info("task {} submitted: {s}", .{ id, cmd });
        return std.fmt.bufPrint(&g_resp_buf,
            "{{\"result\":{{\"id\":{d},\"state\":\"pending\"}}}}",
            .{id},
        ) catch return "{\"error\":\"buf overflow\"}";
    }

    if (matchMethod(msg, "task.list")) {
        q.mu_lock();
        defer q.mu_unlock();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(q.g_ally);
        try out.appendSlice(q.g_ally, "{\"result\":[");

        const start = if (q.g_tasks.items.len > 20) q.g_tasks.items.len - 20 else 0;
        for (q.g_tasks.items[start..], 0..) |*t, i| {
            if (i > 0) try out.append(q.g_ally, ',');
            var tbuf: [256]u8 = undefined;
            try out.appendSlice(q.g_ally, t.toJson(&tbuf));
        }
        try out.appendSlice(q.g_ally, "]}");

        return try q.g_ally.dupe(u8, out.items);
    }

    // ── KB update trigger (called by git hook — see schema/index_contract.json) ─

    if (matchMethod(msg, "index")) {
        const project = extractString(msg, "project") orelse "default";
        const cmd_owned = try q.g_ally.dupe(u8, "krul index");
        q.mu_lock();
        const id = q.g_next_id;
        q.g_next_id += 1;
        try q.g_tasks.append(q.g_ally, .{
            .id           = id,
            .kind         = .index,
            .state        = .pending,
            .cmd          = cmd_owned,
            .exit_code    = 0,
            .stdout_tail  = undefined,
            .stdout_len   = 0,
            .created_ns   = q.nanoTimestamp(),
            .completed_ns = 0,
        });
        q.mu_unlock();
        log.info("index task {} queued for project '{s}'", .{ id, project });
        return std.fmt.bufPrint(&g_resp_buf,
            "{{\"result\":{{\"task_id\":{d},\"project\":\"{s}\",\"state\":\"queued\"}}}}",
            .{ id, project },
        ) catch return "{\"error\":\"buf overflow\"}";
    }

    // ── KB retrieval queries ──────────────────────────────────────────────────

    if (matchMethod(msg, "query")) {
        const db = q.g_db orelse return "{\"error\":\"db not connected\"}";
        const query_type = extractString(msg, "type") orelse
            return "{\"error\":\"missing type (entities|relations|context|no_covergroup)\"}";
        const project = extractString(msg, "project");
        const pid = kb.resolveProject(db, project);

        const data = blk: {
            if (std.mem.eql(u8, query_type, "entities")) {
                const kind = extractString(msg, "kind");
                const name_pat = extractString(msg, "name");
                break :blk kb.entities(db, pid, kind, name_pat, &g_data_buf) catch
                    return "{\"error\":\"query_entities failed\"}";
            } else if (std.mem.eql(u8, query_type, "relations")) {
                const from = extractString(msg, "from");
                const rel = extractString(msg, "rel");
                break :blk kb.relations(db, pid, from, rel, &g_data_buf) catch
                    return "{\"error\":\"query_relations failed\"}";
            } else if (std.mem.eql(u8, query_type, "context")) {
                const focus = extractString(msg, "focus") orelse
                    return "{\"error\":\"missing focus\"}";
                const depth = extractInt(msg, "depth") orelse 1;
                break :blk kb.context(db, pid, focus, depth, &g_data_buf) catch
                    return "{\"error\":\"get_context failed\"}";
            } else if (std.mem.eql(u8, query_type, "no_covergroup")) {
                break :blk kb.noCovergroup(db, pid, &g_data_buf) catch
                    return "{\"error\":\"no_covergroup failed\"}";
            } else {
                return "{\"error\":\"unknown type — use entities|relations|context|no_covergroup\"}";
            }
        };

        return std.fmt.bufPrint(&g_resp_buf, "{{\"result\":{s}}}", .{data}) catch
            return "{\"error\":\"response too large\"}";
    }

    if (matchMethod(msg, "triage")) {
        const project = extractString(msg, "project") orelse "default";
        return std.fmt.bufPrint(&g_resp_buf,
            "{{\"result\":{{\"state\":\"queued\",\"project\":\"{s}\"," ++
            "\"note\":\"LLM triage wired in Phase 4\"}}}}",
            .{project},
        ) catch return "{\"error\":\"buf overflow\"}";
    }

    if (matchMethod(msg, "coverage_gaps")) {
        const db = q.g_db orelse return "{\"error\":\"db not connected\"}";
        const project = extractString(msg, "project");
        const pid = kb.resolveProject(db, project);
        const data = kb.noCovergroup(db, pid, &g_data_buf) catch
            return "{\"error\":\"coverage_gaps query failed\"}";
        return std.fmt.bufPrint(&g_resp_buf, "{{\"result\":{s}}}", .{data}) catch
            return "{\"error\":\"response too large\"}";
    }

    // ── LLM pool ──────────────────────────────────────────────────────────────

    if (matchMethod(msg, "llm.call")) {
        const cfg = llm.g_cfg orelse return "{\"error\":\"LLM not configured\"}";
        const user   = extractString(msg, "user")   orelse return "{\"error\":\"missing user\"}";
        const system = extractString(msg, "system") orelse "";

        const resp = llm.call(q.g_ally, cfg, .{ .system = system, .user = user }) catch |err| {
            log.warn("llm.call failed: {}", .{err});
            return "{\"error\":\"llm call failed\"}";
        };
        defer q.g_ally.free(resp.content);

        // Escape content into g_data_buf, then wrap in g_resp_buf
        var di: usize = 0;
        for (resp.content) |ch| {
            switch (ch) {
                '"'  => { if (di + 2 > g_data_buf.len) break; g_data_buf[di] = '\\'; g_data_buf[di+1] = '"';  di += 2; },
                '\\' => { if (di + 2 > g_data_buf.len) break; g_data_buf[di] = '\\'; g_data_buf[di+1] = '\\'; di += 2; },
                '\n' => { if (di + 2 > g_data_buf.len) break; g_data_buf[di] = '\\'; g_data_buf[di+1] = 'n';  di += 2; },
                '\r' => { if (di + 2 > g_data_buf.len) break; g_data_buf[di] = '\\'; g_data_buf[di+1] = 'r';  di += 2; },
                '\t' => { if (di + 2 > g_data_buf.len) break; g_data_buf[di] = '\\'; g_data_buf[di+1] = 't';  di += 2; },
                else => { if (di + 1 > g_data_buf.len) break; g_data_buf[di] = ch; di += 1; },
            }
        }
        return std.fmt.bufPrint(&g_resp_buf,
            "{{\"result\":{{\"content\":\"{s}\",\"input_tokens\":{d},\"output_tokens\":{d},\"latency_ms\":{d}}}}}",
            .{ g_data_buf[0..di], resp.input_tokens, resp.output_tokens, resp.latency_ms },
        ) catch return "{\"error\":\"buf overflow\"}";
    }

    // ── Capability plugin method routing ─────────────────────────────────────
    // Extract method string from msg for plugin lookup.
    if (extractString(msg, "method")) |method| {
        if (plugins.routeMethod(method, msg, &g_data_buf)) |data| {
            return std.fmt.bufPrint(&g_resp_buf, "{{\"result\":{s}}}", .{data}) catch
                return "{\"error\":\"response too large\"}";
        }
    }

    // ── Router classification ─────────────────────────────────────────────────

    if (matchMethod(msg, "router.classify")) {
        const qstr = extractString(msg, "q") orelse extractString(msg, "query") orelse
            return "{\"error\":\"missing q\"}";
        const decision = router.classify(qstr);
        return switch (decision) {
            .structural => |kind| std.fmt.bufPrint(&g_resp_buf,
                "{{\"result\":{{\"route\":\"structural\",\"kind\":\"{s}\"}}}}",
                .{kind.name()},
            ) catch return "{\"error\":\"buf overflow\"}",
            .gear => |g| std.fmt.bufPrint(&g_resp_buf,
                "{{\"result\":{{\"route\":\"gear\",\"name\":\"{s}\"}}}}",
                .{g.name},
            ) catch return "{\"error\":\"buf overflow\"}",
            .embedding_needed => "{\"result\":{\"route\":\"embedding_needed\"}}",
            .llm_needed       => "{\"result\":{\"route\":\"llm_needed\"}}",
        };
    }

    // ── Gear executor ─────────────────────────────────────────────────────────

    if (matchMethod(msg, "gear.run")) {
        const query = extractString(msg, "query") orelse extractString(msg, "q") orelse
            return "{\"error\":\"missing query\"}";

        const decision = router.classify(query);

        // Structural queries bypass the gear executor entirely.
        if (decision == .structural) {
            const db = q.g_db orelse return "{\"error\":\"db not connected\"}";
            const project = extractString(msg, "project");
            const pid = kb.resolveProject(db, project);
            const kind = decision.structural;
            const data: []const u8 = if (kind == .entities)
                kb.entities(db, pid, null, null, &g_data_buf) catch
                    return "{\"error\":\"structural query failed\"}"
            else if (kind == .relations)
                kb.relations(db, pid, null, null, &g_data_buf) catch
                    return "{\"error\":\"structural query failed\"}"
            else if (kind == .no_covergroup)
                kb.noCovergroup(db, pid, &g_data_buf) catch
                    return "{\"error\":\"structural query failed\"}"
            else data_blk: {
                const focus = extractString(msg, "focus") orelse query;
                break :data_blk kb.context(db, pid, focus, 1, &g_data_buf) catch
                    return "{\"error\":\"structural query failed\"}";
            };
            return std.fmt.bufPrint(&g_resp_buf,
                "{{\"result\":{{\"route\":\"structural\",\"kind\":\"{s}\",\"data\":{s}}}}}",
                .{ kind.name(), data },
            ) catch return "{\"error\":\"buf overflow\"}";
        }

        const g = switch (decision) {
            .gear => |g| g,
            else  => return "{\"result\":{\"matched\":false}}",
        };

        log.info("gear.run: matched '{s}' for query '{s}'", .{ g.name, query });

        const output = executor.run(q.g_ally, g, query, "") catch |err| {
            log.warn("gear.run '{s}' failed: {}", .{ g.name, err });
            return "{\"error\":\"gear execution failed\"}";
        };
        defer q.g_ally.free(output);

        var di: usize = 0;
        for (output) |ch| {
            if (di + 2 >= g_data_buf.len) break;
            switch (ch) {
                '"'  => { g_data_buf[di] = '\\'; g_data_buf[di+1] = '"';  di += 2; },
                '\\' => { g_data_buf[di] = '\\'; g_data_buf[di+1] = '\\'; di += 2; },
                '\n' => { g_data_buf[di] = '\\'; g_data_buf[di+1] = 'n';  di += 2; },
                '\r' => { g_data_buf[di] = '\\'; g_data_buf[di+1] = 'r';  di += 2; },
                '\t' => { g_data_buf[di] = '\\'; g_data_buf[di+1] = 't';  di += 2; },
                else => { g_data_buf[di] = ch; di += 1; },
            }
        }

        return std.fmt.bufPrint(&g_resp_buf,
            "{{\"result\":{{\"gear\":\"{s}\",\"output\":\"{s}\"}}}}",
            .{ g.name, g_data_buf[0..di] },
        ) catch return "{\"error\":\"buf overflow\"}";
    }

    // ── Gear lookup ───────────────────────────────────────────────────────────
    if (matchMethod(msg, "gear.find")) {
        const query = extractString(msg, "q") orelse extractString(msg, "query") orelse
            return "{\"error\":\"missing q\"}";
        if (gears.findGear(query)) |g| {
            return std.fmt.bufPrint(&g_resp_buf,
                "{{\"result\":{{\"name\":\"{s}\",\"stages\":{d},\"triggers\":{d}}}}}",
                .{ g.name, g.stages.len, g.triggers.len },
            ) catch return "{\"error\":\"buf overflow\"}";
        }
        return "{\"result\":null}";
    }

    return "{\"error\":\"unknown method\"}";
}

fn matchMethod(msg: []const u8, method: []const u8) bool {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"method\":\"{s}\"", .{method}) catch return false;
    return std.mem.indexOf(u8, msg, needle) != null;
}

fn extractString(msg: []const u8, field: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{field}) catch return null;
    const start_idx = (std.mem.indexOf(u8, msg, key) orelse return null) + key.len;
    const end_idx = std.mem.indexOf(u8, msg[start_idx..], "\"") orelse return null;
    return msg[start_idx .. start_idx + end_idx];
}

fn extractInt(msg: []const u8, field: []const u8) ?i32 {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{field}) catch return null;
    const after = (std.mem.indexOf(u8, msg, key) orelse return null) + key.len;
    var i = after;
    while (i < msg.len and msg[i] == ' ') i += 1;
    const num_start = i;
    while (i < msg.len and msg[i] >= '0' and msg[i] <= '9') i += 1;
    if (i == num_start) return null;
    return std.fmt.parseInt(i32, msg[num_start..i], 10) catch null;
}
