//! Minimal JSON-RPC 2.0 envelope handling.

const std = @import("std");

pub const code_parse_error: i64 = -32700;
pub const code_invalid_request: i64 = -32600;
pub const code_method_not_found: i64 = -32601;
pub const code_invalid_params: i64 = -32602;
pub const code_internal_error: i64 = -32603;

pub const Request = struct {
    id: std.json.Value,
    is_notification: bool,
    method: []const u8,
    params: ?std.json.Value,
};

pub const ParseResult = union(enum) {
    request: Request,
    invalid: Invalid,

    pub const Invalid = struct { code: i64, message: []const u8 };
};

pub fn parse(arena: std.mem.Allocator, body: []const u8) error{OutOfMemory}!ParseResult {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .invalid = .{ .code = code_parse_error, .message = "Parse error" } },
    };
    const obj = switch (root) {
        .object => |o| o,
        // JSON-RPC batching was removed in MCP 2025-06-18; arrays are rejected.
        else => return .{ .invalid = .{ .code = code_invalid_request, .message = "Invalid Request" } },
    };
    const method = switch (obj.get("method") orelse
        return .{ .invalid = .{ .code = code_invalid_request, .message = "Invalid Request: missing method" } }) {
        .string => |s| s,
        else => return .{ .invalid = .{ .code = code_invalid_request, .message = "Invalid Request: method must be a string" } },
    };
    const id = obj.get("id");
    return .{ .request = .{
        .id = id orelse .null,
        .is_notification = id == null,
        .method = method,
        .params = obj.get("params"),
    } };
}

/// Build `{"jsonrpc":"2.0","id":<id>,"result":<raw_result>}`.
/// `raw_result` must be valid JSON.
pub fn success(arena: std.mem.Allocator, id: std.json.Value, raw_result: []const u8) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeSuccess(&s, id, raw_result) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeSuccess(s: *std.json.Stringify, id: std.json.Value, raw_result: []const u8) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("result");
    try s.beginWriteRaw();
    try s.writer.writeAll(raw_result);
    s.endWriteRaw();
    try s.endObject();
}

/// Build `{"jsonrpc":"2.0","id":<id>,"error":{"code":<code>,"message":<message>}}`.
pub fn failure(arena: std.mem.Allocator, id: std.json.Value, code: i64, message: []const u8) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeFailure(&s, id, code, message) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeFailure(s: *std.json.Stringify, id: std.json.Value, code: i64, message: []const u8) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();
}

test "parse distinguishes requests from notifications" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try parse(arena, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}");
    try std.testing.expect(!r.request.is_notification);
    try std.testing.expectEqual(@as(i64, 7), r.request.id.integer);
    try std.testing.expectEqualStrings("ping", r.request.method);

    const n = try parse(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try std.testing.expect(n.request.is_notification);
}

test "parse rejects garbage, arrays, and missing method" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(code_parse_error, (try parse(arena, "{nope")).invalid.code);
    try std.testing.expectEqual(code_invalid_request, (try parse(arena, "[]")).invalid.code);
    try std.testing.expectEqual(code_invalid_request, (try parse(arena, "{\"id\":1}")).invalid.code);
    try std.testing.expectEqual(code_invalid_request, (try parse(arena, "{\"method\":5}")).invalid.code);
    try std.testing.expectEqual(code_invalid_request, (try parse(arena, "\"ping\"")).invalid.code);
}

test "string ids survive the round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try parse(arena, "{\"jsonrpc\":\"2.0\",\"id\":\"req-9\",\"method\":\"ping\"}");
    try std.testing.expectEqualStrings("req-9", r.request.id.string);

    const ok = try success(arena, r.request.id, "{}");
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"req-9\",\"result\":{}}", ok);
}

test "failure escapes the error message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad = try failure(arena, .{ .integer = 1 }, code_internal_error, "quote \" and \\ backslash");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bad, .{});
    try std.testing.expectEqualStrings(
        "quote \" and \\ backslash",
        parsed.object.get("error").?.object.get("message").?.string,
    );
}

test "success and failure envelopes are well-formed JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ok = try success(arena, .{ .integer = 1 }, "{\"x\":1}");
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"x\":1}}", ok);

    const bad = try failure(arena, .null, code_method_not_found, "Method not found");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bad, .{});
    try std.testing.expectEqual(code_method_not_found, parsed.object.get("error").?.object.get("code").?.integer);
}
