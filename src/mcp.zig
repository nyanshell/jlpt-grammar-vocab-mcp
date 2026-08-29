//! MCP method dispatch over the Streamable HTTP transport (stateless).
//! Responses are single application/json bodies; no SSE streams, no sessions.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const tools = @import("tools.zig");
const db_mod = @import("db.zig");

pub const server_name = "jlpt-n1-mcp";
pub const server_version = "0.1.0";
pub const default_protocol_version = "2025-06-18";
const supported_protocol_versions = [_][]const u8{ "2024-11-05", "2025-03-26", "2025-06-18" };

pub const HttpResult = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "",
};

pub fn handle(arena: std.mem.Allocator, db: *db_mod.Db, body: []const u8) error{OutOfMemory}!HttpResult {
    const req = switch (try jsonrpc.parse(arena, body)) {
        .invalid => |inv| return .{ .body = try jsonrpc.failure(arena, .null, inv.code, inv.message) },
        .request => |r| r,
    };
    if (req.is_notification) return .{ .status = .accepted };

    if (std.mem.eql(u8, req.method, "initialize"))
        return .{ .body = try initialize(arena, req) };
    if (std.mem.eql(u8, req.method, "ping"))
        return .{ .body = try jsonrpc.success(arena, req.id, "{}") };
    if (std.mem.eql(u8, req.method, "tools/list"))
        return .{ .body = try jsonrpc.success(arena, req.id, tools.list_json) };
    if (std.mem.eql(u8, req.method, "tools/call"))
        return .{ .body = try toolsCall(arena, db, req) };
    return .{ .body = try jsonrpc.failure(arena, req.id, jsonrpc.code_method_not_found, "Method not found") };
}

fn initialize(arena: std.mem.Allocator, req: jsonrpc.Request) error{OutOfMemory}![]u8 {
    var version: []const u8 = default_protocol_version;
    if (req.params) |p| {
        if (p == .object) {
            if (p.object.get("protocolVersion")) |v| {
                if (v == .string) {
                    for (supported_protocol_versions) |sv| {
                        if (std.mem.eql(u8, sv, v.string)) {
                            version = v.string;
                            break;
                        }
                    }
                }
            }
        }
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeInitializeResult(&s, version) catch return error.OutOfMemory;
    return jsonrpc.success(arena, req.id, aw.written());
}

fn writeInitializeResult(s: *std.json.Stringify, version: []const u8) !void {
    try s.beginObject();
    try s.objectField("protocolVersion");
    try s.write(version);
    try s.objectField("capabilities");
    try s.beginWriteRaw();
    try s.writer.writeAll("{\"tools\":{\"listChanged\":false}}");
    s.endWriteRaw();
    try s.objectField("serverInfo");
    try s.beginObject();
    try s.objectField("name");
    try s.write(server_name);
    try s.objectField("title");
    try s.write("JLPT N1 Grammar & Vocabulary");
    try s.objectField("version");
    try s.write(server_version);
    try s.endObject();
    try s.endObject();
}

fn toolsCall(arena: std.mem.Allocator, db: *db_mod.Db, req: jsonrpc.Request) error{OutOfMemory}![]u8 {
    const invalid = jsonrpc.code_invalid_params;
    const params = req.params orelse
        return jsonrpc.failure(arena, req.id, invalid, "Missing params");
    if (params != .object)
        return jsonrpc.failure(arena, req.id, invalid, "params must be an object");
    const name = switch (params.object.get("name") orelse
        return jsonrpc.failure(arena, req.id, invalid, "Missing tool name")) {
        .string => |s| s,
        else => return jsonrpc.failure(arena, req.id, invalid, "Tool name must be a string"),
    };
    const tool = tools.find(name) orelse
        return jsonrpc.failure(arena, req.id, invalid, "Unknown tool");

    var ctx: tools.Ctx = .{ .arena = arena, .db = db };
    const outcome = tool.handler(&ctx, params.object.get("arguments")) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuckDb => tools.Outcome{
            .err = try std.fmt.allocPrint(arena, "database error: {s}", .{db.lastError()}),
        },
    };

    const payload, const is_error = switch (outcome) {
        .ok => |p| .{ p, false },
        .err => |m| .{ m, true },
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeToolResult(&s, payload, is_error) catch return error.OutOfMemory;
    return jsonrpc.success(arena, req.id, aw.written());
}

fn writeToolResult(s: *std.json.Stringify, text: []const u8, is_error: bool) !void {
    try s.beginObject();
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try s.endArray();
    try s.objectField("isError");
    try s.write(is_error);
    try s.endObject();
}
