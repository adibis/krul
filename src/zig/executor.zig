// Gear executor — runs a gear's stages in order, substitutes templates,
// calls the LLM pool or shell for each stage, and returns the final output.
//
// Template tokens: {input} = user query, {context} = entity-store context,
// {stage_id} = prior stage output. \n in prompt strings is unescaped to newline.

const std   = @import("std");
const gear  = @import("gear.zig");
const llm   = @import("llm.zig");
const hooks = @import("hooks.zig");
const c     = @import("c.zig").lib;

const log = std.log.scoped(.executor);

pub const StageOutput = struct {
    content: []u8,
    failed:  bool,
};

/// Run a gear end-to-end. Returns heap-allocated final stage output.
/// Caller must free with ally.free().
pub fn run(
    ally:    std.mem.Allocator,
    g:       *const gear.Gear,
    input:   []const u8,
    context: []const u8,
) ![]u8 {
    var outputs: std.StringHashMapUnmanaged(StageOutput) = .empty;
    defer {
        // Frees both the value's content AND the key -- the key string
        // stored here is always a heap dupe (see the `ally.dupe` call
        // below), never a literal, so deinit() alone leaks every key:
        // StringHashMapUnmanaged has no idea the keys it holds are
        // owned, it only owns its own bucket storage.
        var it = outputs.iterator();
        while (it.next()) |entry| {
            ally.free(entry.key_ptr.*);
            ally.free(entry.value_ptr.content);
        }
        outputs.deinit(ally);
    }

    var last: []u8 = try ally.dupe(u8, "");
    errdefer ally.free(last);

    var iteration: u32 = 0;
    while (iteration < g.max_iterations) : (iteration += 1) {
        log.info("gear '{s}' iteration {d}/{d}", .{ g.name, iteration + 1, g.max_iterations });

        for (g.stages) |stage| {
            const out = runStage(ally, g.name, &stage, input, context, &outputs) catch |err| blk: {
                log.warn("stage '{s}' error: {}", .{ stage.id, err });
                break :blk StageOutput{
                    .content = try ally.dupe(u8, ""),
                    .failed  = true,
                };
            };

            const stage_failed = out.failed;
            if (outputs.getPtr(stage.id)) |existing| {
                ally.free(existing.content);
                existing.* = out;
            } else {
                const key = try ally.dupe(u8, stage.id);
                try outputs.put(ally, key, out);
            }

            // Notification only -- a stage's own result already decided
            // whether to proceed; nothing here can reopen that decision.
            var stage_hp: [128]u8 = undefined;
            const shp = std.fmt.bufPrint(&stage_hp,
                "{{\"gear\":\"{s}\",\"stage\":\"{s}\",\"failed\":{}}}",
                .{ g.name, stage.id, stage_failed }) catch stage_hp[0..0];
            hooks.fire("on_stage_complete", shp);
        }

        // Termination: last stage succeeded and condition is met
        const last_stage = g.stages[g.stages.len - 1];
        if (outputs.get(last_stage.id)) |out| {
            if (!out.failed) {
                ally.free(last);
                last = try ally.dupe(u8, out.content);
                if (checkTermination(g.termination_condition, &outputs)) {
                    log.info("gear '{s}' done after iteration {d}", .{ g.name, iteration + 1 });
                    fireGearComplete(g.name, iteration + 1, "done");
                    return last;
                }
            }
        }
    }

    log.warn("gear '{s}' hit max_iterations={d}", .{ g.name, g.max_iterations });
    fireGearComplete(g.name, g.max_iterations, "max_iterations");
    return last;
}

/// Notification only, same as on_stage_complete -- a registered handler
/// (write a finding to memory, bump a pheromone's reinforcement, enqueue
/// a regression via the existing task queue, notify the user) reacts to
/// a gear finishing. Nothing here can undo that the gear already ran.
fn fireGearComplete(gear_name: []const u8, iterations: u32, reason: []const u8) void {
    var hp: [160]u8 = undefined;
    const payload = std.fmt.bufPrint(&hp,
        "{{\"gear\":\"{s}\",\"iterations\":{d},\"reason\":\"{s}\"}}",
        .{ gear_name, iterations, reason }) catch hp[0..0];
    hooks.fire("on_gear_complete", payload);
}

fn runStage(
    ally:      std.mem.Allocator,
    gear_name: []const u8,
    stage:     *const gear.Stage,
    input:     []const u8,
    context:   []const u8,
    outputs:   *std.StringHashMapUnmanaged(StageOutput),
) !StageOutput {
    switch (stage.kind) {
        .llm, .parallel_llm => {
            const cfg = llm.g_cfg orelse return error.LlmNotConfigured;
            const prompt = try fillTemplate(ally, stage.prompt, input, context, outputs);
            defer ally.free(prompt);

            log.info("stage '{s}' [llm] prompt={d}B", .{ stage.id, prompt.len });
            if (stage.kind == .parallel_llm) {
                // Phase 6 upgrades this to true fan-out; for now single call
                log.info("parallel_llm '{s}': running as single call until Phase 6", .{stage.id});
            }

            const resp = try llm.call(ally, cfg, .{
                .system = "You are a chip design verification expert working with SystemVerilog and UVM testbenches. Be concise and precise.",
                .user   = prompt,
            });
            log.info("stage '{s}' ok: in={d} out={d} lat={d}ms",
                .{ stage.id, resp.input_tokens, resp.output_tokens, resp.latency_ms });
            return .{ .content = resp.content, .failed = false };
        },

        .process => {
            const cmd = try fillTemplate(ally, stage.prompt, input, context, outputs);
            defer ally.free(cmd);

            if (hooks.gateProcess(ally, gear_name, stage.id, cmd) == .deny) {
                log.warn("stage '{s}' [process] denied by gate", .{stage.id});
                return .{ .content = try ally.dupe(u8, "denied by gate"), .failed = true };
            }

            const snip = cmd[0..@min(cmd.len, 80)];
            log.info("stage '{s}' [process] cmd={s}", .{ stage.id, snip });

            const cmd_z = try ally.dupeZ(u8, cmd);
            defer ally.free(cmd_z);

            var stdout: [4096]u8 = undefined;
            var exit: c_int = 0;
            _ = c.krl_exec_shell(cmd_z.ptr, &stdout, stdout.len, &exit);
            const n = std.mem.indexOfScalar(u8, &stdout, 0) orelse stdout.len;
            log.info("stage '{s}' exit={d} out={d}B", .{ stage.id, exit, n });

            return .{
                .content = try ally.dupe(u8, stdout[0..n]),
                .failed  = exit != 0,
            };
        },

        .condition => {
            return .{ .content = try ally.dupe(u8, ""), .failed = false };
        },
    }
}

/// Template engine: substitutes {input}, {context}, {stage_id} tokens.
/// Also unescapes \n → newline in the template text.
fn fillTemplate(
    ally:    std.mem.Allocator,
    tmpl:    []const u8,
    input:   []const u8,
    context: []const u8,
    outputs: *std.StringHashMapUnmanaged(StageOutput),
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ally);

    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] == '{') {
            const close = std.mem.indexOfScalar(u8, tmpl[i + 1 ..], '}') orelse {
                try out.append(ally, '{');
                i += 1;
                continue;
            };
            const key = tmpl[i + 1 .. i + 1 + close];
            if (std.mem.eql(u8, key, "input")) {
                try out.appendSlice(ally, input);
            } else if (std.mem.eql(u8, key, "context")) {
                try out.appendSlice(ally, context);
            } else if (outputs.get(key)) |prev| {
                try out.appendSlice(ally, prev.content);
            } else {
                try out.append(ally, '{');
                try out.appendSlice(ally, key);
                try out.append(ally, '}');
            }
            i += close + 2;
        } else if (tmpl[i] == '\\' and i + 1 < tmpl.len and tmpl[i + 1] == 'n') {
            try out.append(ally, '\n');
            i += 2;
        } else {
            try out.append(ally, tmpl[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(ally);
}

/// Returns true if the termination condition is met.
/// Supports: "<stage_id>.status == done"
fn checkTermination(
    condition: []const u8,
    outputs:   *std.StringHashMapUnmanaged(StageOutput),
) bool {
    const dot = std.mem.indexOfScalar(u8, condition, '.') orelse return true;
    const stage_id = condition[0..dot];
    const rest = condition[dot + 1 ..];
    if (std.mem.startsWith(u8, rest, "status == done")) {
        const out = outputs.get(stage_id) orelse return false;
        return !out.failed;
    }
    return true;
}

const canary_path = "/tmp/krul_gate_test_canary";

test "process stage runs normally when no gate script is configured" {
    hooks.init("");
    const ally = std.testing.allocator;
    var outputs: std.StringHashMapUnmanaged(StageOutput) = .empty;
    defer outputs.deinit(ally);

    const stage = gear.Stage{ .id = "s", .kind = .process, .prompt = "echo hi" };
    const out = try runStage(ally, "g", &stage, "", "", &outputs);
    defer ally.free(out.content);

    try std.testing.expect(!out.failed);
    try std.testing.expect(std.mem.indexOf(u8, out.content, "hi") != null);
}

test "process stage is denied by gate script, and the command never actually runs" {
    _ = std.c.unlink(canary_path);
    hooks.init("tests/fixtures/gate_deny.sh");
    defer hooks.init("");

    const ally = std.testing.allocator;
    var outputs: std.StringHashMapUnmanaged(StageOutput) = .empty;
    defer outputs.deinit(ally);

    const stage = gear.Stage{
        .id = "s", .kind = .process,
        .prompt = "echo x > " ++ canary_path,
    };
    const out = try runStage(ally, "g", &stage, "", "", &outputs);
    defer ally.free(out.content);

    try std.testing.expect(out.failed);
    try std.testing.expectEqualStrings("denied by gate", out.content);
    // Not just checking the reported status -- proves the shell command
    // itself never executed, not merely that the stage was labeled failed.
    try std.testing.expect(std.c.fopen(canary_path, "r") == null);
}

test "process stage runs when gate script allows it" {
    _ = std.c.unlink(canary_path);
    hooks.init("tests/fixtures/gate_allow.sh");
    defer hooks.init("");

    const ally = std.testing.allocator;
    var outputs: std.StringHashMapUnmanaged(StageOutput) = .empty;
    defer outputs.deinit(ally);

    const stage = gear.Stage{
        .id = "s", .kind = .process,
        .prompt = "echo x > " ++ canary_path,
    };
    const out = try runStage(ally, "g", &stage, "", "", &outputs);
    defer ally.free(out.content);

    try std.testing.expect(!out.failed);
    const f = std.c.fopen(canary_path, "r");
    try std.testing.expect(f != null);
    if (f) |fp| _ = std.c.fclose(fp);
    _ = std.c.unlink(canary_path);
}

var test_stage_payload_buf: [160]u8 = undefined;
var test_stage_payload_len: usize = 0;
var test_gear_payload_buf: [160]u8 = undefined;
var test_gear_payload_len: usize = 0;

fn captureStagePayload(payload: []const u8) void {
    test_stage_payload_len = @min(payload.len, test_stage_payload_buf.len);
    @memcpy(test_stage_payload_buf[0..test_stage_payload_len], payload[0..test_stage_payload_len]);
}

fn captureGearPayload(payload: []const u8) void {
    test_gear_payload_len = @min(payload.len, test_gear_payload_buf.len);
    @memcpy(test_gear_payload_buf[0..test_gear_payload_len], payload[0..test_gear_payload_len]);
}

test "on_stage_complete and on_gear_complete fire with the expected payloads" {
    hooks.init("");
    hooks.register("on_stage_complete", captureStagePayload);
    hooks.register("on_gear_complete", captureGearPayload);

    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    const gear_ally = arena.allocator();

    const stages = try gear_ally.alloc(gear.Stage, 1);
    stages[0] = .{ .id = "only_stage", .kind = .process, .prompt = "echo done" };

    var g = gear.Gear{
        .name = "test_gear_for_hooks",
        .version = 1,
        .triggers = &.{},
        .stages = stages,
        .termination_condition = "only_stage.status == done",
        .max_iterations = 1,
        .on_max = "return_last",
        ._arena = arena,
    };
    defer g.deinit();

    const out = try run(ally, &g, "", "");
    defer ally.free(out);

    const stage_payload = test_stage_payload_buf[0..test_stage_payload_len];
    try std.testing.expect(std.mem.indexOf(u8, stage_payload, "\"stage\":\"only_stage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stage_payload, "\"failed\":false") != null);

    const gear_payload = test_gear_payload_buf[0..test_gear_payload_len];
    try std.testing.expect(std.mem.indexOf(u8, gear_payload, "\"gear\":\"test_gear_for_hooks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, gear_payload, "\"reason\":\"done\"") != null);
}
