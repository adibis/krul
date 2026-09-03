const std = @import("std");
const net = std.Io.net;
const Dir = std.Io.Dir;

const log = std.log.scoped(.krul);

const sock_path = "/tmp/krul.sock";

pub fn main(init: std.process.Init) !void {
    const ally = init.gpa;
    const io   = init.io;

    const args_slice = try init.minimal.args.toSlice(init.arena.allocator());

    if (args_slice.len < 2) {
        usage(args_slice[0]);
        return;
    }

    const cmd = args_slice[1];
    if (std.mem.eql(u8, cmd, "query")) {
        try cmd_query(io, ally, args_slice[2..]);
    } else if (std.mem.eql(u8, cmd, "triage")) {
        try cmd_triage(io, ally, args_slice[2..]);
    } else if (std.mem.eql(u8, cmd, "coverage-gaps")) {
        try cmd_coverage_gaps(io, ally, args_slice[2..]);
    } else {
        log.err("unknown command: {s}", .{cmd});
        usage(args_slice[0]);
        std.process.exit(1);
    }
}

fn usage(prog: []const u8) void {
    std.debug.print(
        \\Usage: {s} <command> [args...]
        \\
        \\Commands:
        \\  query <question>               Natural-language graph query
        \\  triage [--commit <ref>]        Triage assertions from last regression
        \\  coverage-gaps [--report <xml>] Show uncovered bins with graph context
        \\
    , .{prog});
}

fn daemon_rpc(io: std.Io, ally: std.mem.Allocator, request: []const u8) ![]u8 {
    const unix_addr = net.UnixAddress.init(sock_path) catch {
        std.debug.print("error: invalid socket path\n", .{});
        std.process.exit(1);
    };
    var stream = unix_addr.connect(io) catch {
        std.debug.print("error: kruld is not running. Start it with 'kruld start'.\n", .{});
        std.process.exit(1);
    };
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const resp = try reader.interface.takeDelimiterExclusive('\n');

    return try ally.dupe(u8, resp);
}

fn cmd_query(io: std.Io, ally: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("usage: krul query <question>\n", .{});
        std.process.exit(1);
    }

    const question = try std.mem.join(ally, " ", args);
    defer ally.free(question);

    const request = try std.fmt.allocPrint(
        ally,
        "{{\"method\":\"query\",\"params\":{{\"q\":\"{s}\"}}}}\n",
        .{question},
    );
    defer ally.free(request);

    const response = try daemon_rpc(io, ally, request);
    defer ally.free(response);
    std.debug.print("{s}\n", .{response});
}

fn cmd_triage(io: std.Io, ally: std.mem.Allocator, args: []const []const u8) !void {
    var commit: []const u8 = "HEAD";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--commit") and i + 1 < args.len) {
            commit = args[i + 1];
            i += 1;
        }
    }

    const request = try std.fmt.allocPrint(
        ally,
        "{{\"method\":\"triage\",\"params\":{{\"commit\":\"{s}\"}}}}\n",
        .{commit},
    );
    defer ally.free(request);

    const response = try daemon_rpc(io, ally, request);
    defer ally.free(response);
    std.debug.print("{s}\n", .{response});
}

fn cmd_coverage_gaps(io: std.Io, ally: std.mem.Allocator, args: []const []const u8) !void {
    var report_path: []const u8 = "sim/coverage/latest.xml";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--report") and i + 1 < args.len) {
            report_path = args[i + 1];
            i += 1;
        }
    }

    const request = try std.fmt.allocPrint(
        ally,
        "{{\"method\":\"coverage_gaps\",\"params\":{{\"report\":\"{s}\"}}}}\n",
        .{report_path},
    );
    defer ally.free(request);

    const response = try daemon_rpc(io, ally, request);
    defer ally.free(response);
    std.debug.print("{s}\n", .{response});
}
