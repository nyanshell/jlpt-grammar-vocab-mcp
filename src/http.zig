//! HTTP front end: accept loop, routing, secret-path check.
//!
//! Each connection is served on its own detached thread, so an idle
//! keep-alive connection (a proxy, a healthcheck, an MCP client pool)
//! never blocks other clients. DuckDB access is serialized with a mutex:
//! a duckdb_connection is not safe for concurrent queries.

const std = @import("std");
const mcp = @import("mcp.zig");
const db_mod = @import("db.zig");

pub const Config = struct {
    bind: []const u8,
    port: u16,
    secret: []const u8,
};

const max_body_bytes = 1024 * 1024;

const Shared = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *db_mod.Db,
    config: Config,
    db_mutex: std.Io.Mutex = .init,
};

pub fn serve(io: std.Io, gpa: std.mem.Allocator, db: *db_mod.Db, config: Config) !void {
    const addr = try std.Io.net.IpAddress.parse(config.bind, config.port);
    var tcp = try addr.listen(io, .{ .reuse_address = true });
    defer tcp.deinit(io);
    std.debug.print("listening on {s}:{d}\n", .{ config.bind, config.port });

    var shared: Shared = .{ .io = io, .gpa = gpa, .db = db, .config = config };

    while (true) {
        const stream = tcp.accept(io) catch |err| {
            std.debug.print("accept failed: {t}\n", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, handleConnection, .{ &shared, stream }) catch |err| {
            std.debug.print("thread spawn failed: {t}\n", .{err});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(shared: *Shared, stream: std.Io.net.Stream) void {
    const io = shared.io;
    defer stream.close(io);
    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var sr = stream.reader(io, &recv_buf);
    var sw = stream.writer(io, &send_buf);
    var server = std.http.Server.init(&sr.interface, &sw.interface);

    while (server.reader.state == .ready) {
        var req = server.receiveHead() catch return;
        handleRequest(shared, &req) catch return;
    }
}

/// Pure routing decision: what to do with a request, given its method,
/// raw target (query string still attached), and the configured secret.
const Route = enum { healthz, mcp, method_not_allowed, not_found };

fn route(method: std.http.Method, target: []const u8, secret: []const u8) Route {
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
    if (std.mem.eql(u8, path, "/healthz")) return .healthz;
    if (std.mem.startsWith(u8, path, "/mcp/")) {
        // A wrong secret is a 404, not a 403: no oracle for path probing.
        if (!secretMatches(path["/mcp/".len..], secret)) return .not_found;
        if (method != .POST) return .method_not_allowed;
        return .mcp;
    }
    return .not_found;
}

fn handleRequest(shared: *Shared, req: *std.http.Server.Request) !void {
    switch (route(req.head.method, req.head.target, shared.config.secret)) {
        .healthz => return req.respond("ok\n", .{}),
        .not_found => return req.respond("", .{ .status = .not_found }),
        .method_not_allowed => return req.respond("", .{
            .status = .method_not_allowed,
            .extra_headers = &.{.{ .name = "allow", .value = "POST" }},
        }),
        .mcp => {},
    }

    var arena_state = std.heap.ArenaAllocator.init(shared.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var transfer_buf: [8 * 1024]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&transfer_buf);
    const body = body_reader.allocRemaining(arena, .limited(max_body_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return req.respond("", .{ .status = .payload_too_large }),
        error.OutOfMemory => return req.respond("", .{ .status = .internal_server_error }),
        error.ReadFailed => return err,
    };

    const result = blk: {
        shared.db_mutex.lockUncancelable(shared.io);
        defer shared.db_mutex.unlock(shared.io);
        break :blk mcp.handle(arena, shared.db, body) catch
            return req.respond("", .{ .status = .internal_server_error });
    };
    return req.respond(result.body, .{
        .status = result.status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
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

test "route dispatch table" {
    const secret = "sixteen-byte-key";
    const cases = [_]struct { method: std.http.Method, target: []const u8, want: Route }{
        .{ .method = .GET, .target = "/healthz", .want = .healthz },
        .{ .method = .POST, .target = "/healthz", .want = .healthz },
        // Query strings are stripped before matching.
        .{ .method = .GET, .target = "/healthz?probe=1", .want = .healthz },
        .{ .method = .POST, .target = "/mcp/sixteen-byte-key", .want = .mcp },
        .{ .method = .POST, .target = "/mcp/sixteen-byte-key?x=1", .want = .mcp },
        // Wrong or missing secret is indistinguishable from a missing route.
        .{ .method = .POST, .target = "/mcp/wrong-secret-here", .want = .not_found },
        .{ .method = .POST, .target = "/mcp/", .want = .not_found },
        .{ .method = .POST, .target = "/mcp", .want = .not_found },
        // Extra path segments must not match: the compare is exact.
        .{ .method = .POST, .target = "/mcp/sixteen-byte-key/extra", .want = .not_found },
        // Right secret, wrong method.
        .{ .method = .GET, .target = "/mcp/sixteen-byte-key", .want = .method_not_allowed },
        .{ .method = .DELETE, .target = "/mcp/sixteen-byte-key", .want = .method_not_allowed },
        .{ .method = .GET, .target = "/", .want = .not_found },
        .{ .method = .GET, .target = "/favicon.ico", .want = .not_found },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.want, route(case.method, case.target, secret));
    }
}
