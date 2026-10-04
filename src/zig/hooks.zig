// Hook system — fire-and-forget lifecycle notifications to registered capability
// plugins, plus a gate check that can block a gear's process stage before it
// runs. Hooks are delivered synchronously within the daemon (no goroutines,
// no spawn). The kanban plugin registers notification handlers here at startup.

const std = @import("std");
const c   = @import("c.zig").lib;

const log = std.log.scoped(.hooks);

pub const HookFn = *const fn (payload: []const u8) void;

const HookEntry = struct {
    name: []const u8,
    handler: HookFn,
};

var g_hooks: [64]HookEntry = undefined;
var g_hooks_len: usize = 0;

pub fn register(name: []const u8, handler: HookFn) void {
    if (g_hooks_len >= g_hooks.len) {
        log.warn("hook table full, skipping: {s}", .{name});
        return;
    }
    g_hooks[g_hooks_len] = .{ .name = name, .handler = handler };
    g_hooks_len += 1;
}

pub fn fire(name: []const u8, payload: []const u8) void {
    for (g_hooks[0..g_hooks_len]) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.handler(payload);
        }
    }
}

pub const Decision = enum { allow, deny };

var g_gate_process_script: []const u8 = "";

/// Called once at daemon startup with the configured gate script path.
/// Empty path disables the gate entirely (every stage allowed).
pub fn init(gate_process_script: []const u8) void {
    g_gate_process_script = gate_process_script;
}

/// Runs before every `process`-type gear stage executes. If a gate script is
/// configured, it receives [gear_name, stage_id, cmd] as literal argv
/// entries, no shell involved, so the command text can never be
/// reinterpreted as shell syntax by the gate check itself. Exit 0 allows
/// the stage; any other exit, or a failure to even launch the script,
/// denies it. Denying is the fail-closed default: a gate that can fail
/// open defeats its own purpose. Krul's core has no opinion on what the
/// script actually checks -- that policy belongs to whoever configured
/// krul for this repo.
pub fn gateProcess(
    ally:      std.mem.Allocator,
    gear_name: []const u8,
    stage_id:  []const u8,
    cmd:       []const u8,
) Decision {
    if (g_gate_process_script.len == 0) return .allow;

    const script_z = ally.dupeZ(u8, g_gate_process_script) catch return .deny;
    defer ally.free(script_z);
    const gear_z = ally.dupeZ(u8, gear_name) catch return .deny;
    defer ally.free(gear_z);
    const stage_z = ally.dupeZ(u8, stage_id) catch return .deny;
    defer ally.free(stage_z);
    const cmd_z = ally.dupeZ(u8, cmd) catch return .deny;
    defer ally.free(cmd_z);

    var argv = [_]?[*:0]const u8{ script_z.ptr, gear_z.ptr, stage_z.ptr, cmd_z.ptr, null };

    var exit: c_int = 0;
    const launched = c.krl_exec_argv(script_z.ptr, @ptrCast(&argv), &exit);
    if (launched != 0) {
        log.warn("gate script failed to launch: {s}", .{g_gate_process_script});
        return .deny;
    }
    if (exit != 0) {
        log.warn("gate denied stage '{s}' (gear '{s}'), script exit={d}", .{ stage_id, gear_name, exit });
        return .deny;
    }
    return .allow;
}
