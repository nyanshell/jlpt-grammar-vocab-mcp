//! HTTP front end: accept loop, routing, secret-path check.

const std = @import("std");
const mcp = @import("mcp.zig");
const db_mod = @import("db.zig");

pub const Config = struct {
    bind: []const u8,
    port: u16,
    secret: []const u8,
};

const max_body_bytes = 1024 * 1024;

pub fn serve(io: std.Io, gpa: std.mem.Allocator, db: *db_mod.Db, config: Config) !void {
    const addr = try std.Io.net.IpAddress.parse(config.bind, config.port);
    var tcp = try addr.listen(io, .{ .reuse_address = true });
    defer tcp.deinit(io);
    std.debug.print("listening on {s}:{d}\n", .{ config.bind, config.port });

    while (true) {
        const stream = tcp.accept(io) catch |err| {
            std.debug.print("accept failed: {t}\n", .{err});
            continue;
        };
        handleConnection(io, gpa, db, config, stream);
    }
}

fn handleConnection(io: std.Io, gpa: std.mem.Allocator, db: *db_mod.Db, config: Config, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var sr = stream.reader(io, &recv_buf);
    var sw = stream.writer(io, &send_buf);
    var server = std.http.Server.init(&sr.interface, &sw.interface);

    while (server.reader.state == .ready) {
        var req = server.receiveHead() catch return;
        handleRequest(gpa, db, config, &req) catch return;
    }
}

fn handleRequest(gpa: std.mem.Allocator, db: *db_mod.Db, config: Config, req: *std.http.Server.Request) !void {
    const target = req.head.target;
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];

    if (std.mem.eql(u8, path, "/healthz"))
        return req.respond("ok\n", .{});

    if (std.mem.startsWith(u8, path, "/mcp/")) {
        const provided = path["/mcp/".len..];
        if (!secretMatches(provided, config.secret))
            return req.respond("", .{ .status = .not_found });
        if (req.head.method != .POST)
            return req.respond("", .{
                .status = .method_not_allowed,
                .extra_headers = &.{.{ .name = "allow", .value = "POST" }},
            });

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var transfer_buf: [8 * 1024]u8 = undefined;
        const body_reader = try req.readerExpectContinue(&transfer_buf);
        const body = body_reader.allocRemaining(arena, .limited(max_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return req.respond("", .{ .status = .payload_too_large }),
            error.OutOfMemory => return req.respond("", .{ .status = .internal_server_error }),
            error.ReadFailed => return err,
        };

        const result = mcp.handle(arena, db, body) catch
            return req.respond("", .{ .status = .internal_server_error });
        return req.respond(result.body, .{
            .status = result.status,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

    return req.respond("", .{ .status = .not_found });
}

fn secretMatches(provided: []const u8, secret: []const u8) bool {
    if (provided.len != secret.len) return false;
    var diff: u8 = 0;
    for (provided, secret) |a, b| diff |= a ^ b;
    return diff == 0;
}

test "secretMatches" {
    try std.testing.expect(secretMatches("abc123", "abc123"));
    try std.testing.expect(!secretMatches("abc124", "abc123"));
    try std.testing.expect(!secretMatches("abc12", "abc123"));
    try std.testing.expect(!secretMatches("", "abc123"));
}
