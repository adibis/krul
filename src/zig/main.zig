const std = @import("std");
const q = @import("queue.zig");
const daemon = @import("daemon.zig");
const setup = @import("setup.zig");
const index_cmd = @import("index_cmd.zig");

const log = std.log.scoped(.kruld);

pub const std_options = std.Options{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    q.g_ally = init.gpa;
    const io = init.io;

    const args_slice = try init.minimal.args.toSlice(init.arena.allocator());

    if (args_slice.len < 2) {
        usage(args_slice[0]);
        return;
    }

    const cmd = args_slice[1];
    if (std.mem.eql(u8, cmd, "init")) {
        try setup.cmd_init(io, q.g_ally, args_slice[2..]);
    } else if (std.mem.eql(u8, cmd, "start")) {
        try daemon.cmd_start(io);
    } else if (std.mem.eql(u8, cmd, "stop")) {
        try daemon.cmd_stop(io, q.g_ally);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try daemon.cmd_status(io, q.g_ally);
    } else if (std.mem.eql(u8, cmd, "index")) {
        try index_cmd.cmd_index(q.g_ally, args_slice[2..]);
    } else {
        log.err("unknown command: {s}", .{cmd});
        usage(args_slice[0]);
        std.process.exit(1);
    }
}

fn usage(prog: []const u8) void {
    std.debug.print(
        \\Usage: {s} <command>
        \\
        \\Commands:
        \\  init     Initialize krul in the current project root
        \\  start    Start the daemon (daemonizes by default)
        \\  stop     Stop a running daemon
        \\  status   Show daemon status and task queue stats
        \\  index    Trigger incremental index (called by git hook)
        \\
    , .{prog});
}
