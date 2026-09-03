const std = @import("std");
const c = @import("c.zig").lib;
const hooks = @import("hooks.zig");

const log = std.log.scoped(.executor);

pub const sock_path = "/tmp/krul.sock";
pub const pid_path = "/tmp/kruld.pid";
pub const default_conninfo = "dbname=krul host=localhost";

pub const TaskKind = enum { shell, index, triage };
pub const TaskState = enum { pending, running, done, failed };

pub const Task = struct {
    id: u64,
    kind: TaskKind,
    state: TaskState,
    cmd: []u8,
    exit_code: i32,
    stdout_tail: [512]u8,
    stdout_len: usize,
    created_ns: i64,
    completed_ns: i64,

    pub fn toJson(self: *const Task, buf: []u8) []u8 {
        const state_str = switch (self.state) {
            .pending => "pending",
            .running => "running",
            .done    => "done",
            .failed  => "failed",
        };
        const kind_str = switch (self.kind) {
            .shell  => "shell",
            .index  => "index",
            .triage => "triage",
        };
        return std.fmt.bufPrint(buf,
            "{{\"id\":{d},\"kind\":\"{s}\",\"state\":\"{s}\",\"exit_code\":{d}}}",
            .{ self.id, kind_str, state_str, self.exit_code },
        ) catch buf[0..0];
    }
};

pub var g_ally: std.mem.Allocator = undefined;
pub var g_mu: std.atomic.Mutex = .unlocked;
pub var g_tasks: std.ArrayListUnmanaged(Task) = .empty;
pub var g_next_id: u64 = 1;
pub var g_db: ?*c.KrlDb = null;

pub fn mu_lock() void {
    while (!g_mu.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

pub fn mu_unlock() void {
    g_mu.unlock();
}

pub fn nanoTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
}

pub fn executor_loop(_: void) void {
    while (true) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 500_000_000 };
        _ = std.c.nanosleep(&ts, null);

        var maybe_idx: ?usize = null;
        mu_lock();
        for (g_tasks.items, 0..) |*t, i| {
            if (t.state == .pending) {
                t.state = .running;
                maybe_idx = i;
                break;
            }
        }
        mu_unlock();

        const idx = maybe_idx orelse continue;

        mu_lock();
        const cmd = g_tasks.items[idx].cmd;
        const task_id = g_tasks.items[idx].id;
        mu_unlock();

        if (g_db) |db| {
            _ = c.krl_task_start(db, @intCast(task_id));
        }

        var stdout_buf: [512]u8 = undefined;
        var exit_code: c_int = 0;
        const exec_ok = c.krl_exec_shell(cmd.ptr, &stdout_buf, stdout_buf.len, &exit_code);

        mu_lock();
        if (idx < g_tasks.items.len) {
            var t = &g_tasks.items[idx];
            t.exit_code    = exit_code;
            t.state        = if (exec_ok == 0 and exit_code == 0) .done else .failed;
            t.completed_ns = nanoTimestamp();
            const slen = std.mem.indexOfScalar(u8, &stdout_buf, 0) orelse stdout_buf.len;
            t.stdout_len   = @min(slen, t.stdout_tail.len);
            @memcpy(t.stdout_tail[0..t.stdout_len], stdout_buf[0..t.stdout_len]);
        }
        const final_state  = g_tasks.items[idx].state;
        const stdout_slice = g_tasks.items[idx].stdout_tail[0..g_tasks.items[idx].stdout_len];
        mu_unlock();

        log.info("task {} finished: {} (exit={})", .{ task_id, final_state, exit_code });

        // Fire hook so capability plugins (kanban, etc.) can react.
        var hook_payload: [128]u8 = undefined;
        const hp = std.fmt.bufPrint(&hook_payload,
            "{{\"task_id\":{d},\"exit_code\":{d},\"state\":\"{s}\"}}",
            .{ task_id, exit_code, @tagName(final_state) }) catch hook_payload[0..0];
        hooks.fire("on_task_complete", hp);

        if (g_db) |db| {
            var tail_z: [513]u8 = undefined;
            @memcpy(tail_z[0..stdout_slice.len], stdout_slice);
            tail_z[stdout_slice.len] = 0;
            if (final_state == .done) {
                _ = c.krl_task_done(db, @intCast(task_id), exit_code, &tail_z);
            } else {
                _ = c.krl_task_fail(db, @intCast(task_id), &tail_z);
            }
        }
    }
}
