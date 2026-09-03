// Gear executor — runs a gear's stages in order, substitutes templates,
// calls the LLM pool or shell for each stage, and returns the final output.
//
// Template tokens: {input} = user query, {context} = entity-store context,
// {stage_id} = prior stage output. \n in prompt strings is unescaped to newline.

const std  = @import("std");
const gear = @import("gear.zig");
const llm  = @import("llm.zig");
const c    = @import("c.zig").lib;

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
        var it = outputs.valueIterator();
        while (it.next()) |v| ally.free(v.content);
        outputs.deinit(ally);
    }

    var last: []u8 = try ally.dupe(u8, "");
    errdefer ally.free(last);

    var iteration: u32 = 0;
    while (iteration < g.max_iterations) : (iteration += 1) {
        log.info("gear '{s}' iteration {d}/{d}", .{ g.name, iteration + 1, g.max_iterations });

        for (g.stages) |stage| {
            const out = runStage(ally, &stage, input, context, &outputs) catch |err| blk: {
                log.warn("stage '{s}' error: {}", .{ stage.id, err });
                break :blk StageOutput{
                    .content = try ally.dupe(u8, ""),
                    .failed  = true,
                };
            };

            if (outputs.getPtr(stage.id)) |existing| {
                ally.free(existing.content);
                existing.* = out;
            } else {
                const key = try ally.dupe(u8, stage.id);
                try outputs.put(ally, key, out);
            }
        }

        // Termination: last stage succeeded and condition is met
        const last_stage = g.stages[g.stages.len - 1];
        if (outputs.get(last_stage.id)) |out| {
            if (!out.failed) {
                ally.free(last);
                last = try ally.dupe(u8, out.content);
                if (checkTermination(g.termination_condition, &outputs)) {
                    log.info("gear '{s}' done after iteration {d}", .{ g.name, iteration + 1 });
                    return last;
                }
            }
        }
    }

    log.warn("gear '{s}' hit max_iterations={d}", .{ g.name, g.max_iterations });
    return last;
}

fn runStage(
    ally:    std.mem.Allocator,
    stage:   *const gear.Stage,
    input:   []const u8,
    context: []const u8,
    outputs: *std.StringHashMapUnmanaged(StageOutput),
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
