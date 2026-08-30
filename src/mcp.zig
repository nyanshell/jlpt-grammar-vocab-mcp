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

// --- tests --------------------------------------------------------------

const testing = std.testing;

const TestEnv = struct {
    db: db_mod.Db,
    arena_state: std.heap.ArenaAllocator,

    fn init(env: *TestEnv) !void {
        env.db = try db_mod.Db.open(":memory:");
        errdefer env.db.close();
        try env.db.exec(db_mod.schema_sql);
        try env.db.exec(
            \\INSERT INTO grammar_points (id, pattern, meaning) VALUES (1, '〜ならでは', 'unique to; only possible with');
        );
        env.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(env: *TestEnv) void {
        env.arena_state.deinit();
        env.db.close();
    }

    fn arena(env: *TestEnv) std.mem.Allocator {
        return env.arena_state.allocator();
    }

    /// Run one body through handle(), expect HTTP 200, parse the JSON-RPC envelope.
    fn call(env: *TestEnv, body: []const u8) !std.json.Value {
        const res = try handle(env.arena(), &env.db, body);
        try testing.expectEqual(std.http.Status.ok, res.status);
        return std.json.parseFromSliceLeaky(std.json.Value, env.arena(), res.body, .{});
    }

    fn callExpectResult(env: *TestEnv, body: []const u8) !std.json.Value {
        const envelope = try env.call(body);
        return envelope.object.get("result") orelse error.MissingResult;
    }

    fn callExpectErrorCode(env: *TestEnv, body: []const u8) !i64 {
        const envelope = try env.call(body);
        const err = envelope.object.get("error") orelse return error.MissingError;
        return err.object.get("code").?.integer;
    }
};

/// Unwrap {"content":[{"type":"text","text":...}],"isError":...} into
/// the inner payload, asserting the expected isError flag.
fn toolText(result: std.json.Value, expect_error: bool) ![]const u8 {
    try testing.expectEqual(expect_error, result.object.get("isError").?.bool);
    const content = result.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    const block = content.items[0].object;
    try testing.expectEqualStrings("text", block.get("type").?.string);
    return block.get("text").?.string;
}

test "initialize negotiates the protocol version" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // A supported client version is echoed back.
    const old = try env.callExpectResult(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
    );
    try testing.expectEqualStrings("2024-11-05", old.object.get("protocolVersion").?.string);
    try testing.expectEqualStrings(server_name, old.object.get("serverInfo").?.object.get("name").?.string);

    // Unknown client versions fall back to the server default.
    const future = try env.callExpectResult(
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}
    );
    try testing.expectEqualStrings(default_protocol_version, future.object.get("protocolVersion").?.string);

    // So do missing params.
    const bare = try env.callExpectResult(
        \\{"jsonrpc":"2.0","id":3,"method":"initialize"}
    );
    try testing.expectEqualStrings(default_protocol_version, bare.object.get("protocolVersion").?.string);
    try testing.expect(bare.object.get("capabilities").?.object.get("tools") != null);
}

test "notifications get HTTP 202 with an empty body" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const res = try handle(env.arena(), &env.db,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    try testing.expectEqual(std.http.Status.accepted, res.status);
    try testing.expectEqualStrings("", res.body);
}

test "ping returns an empty result and echoes the id" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const envelope = try env.call(
        \\{"jsonrpc":"2.0","id":"ping-1","method":"ping"}
    );
    try testing.expectEqualStrings("ping-1", envelope.object.get("id").?.string);
    try testing.expectEqual(@as(usize, 0), envelope.object.get("result").?.object.count());
}

test "tools/list returns every registered tool" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const result = try env.callExpectResult(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    const listed = result.object.get("tools").?.array;
    try testing.expectEqual(tools.registry.len, listed.items.len);
    // Every entry carries the fields Claude requires.
    for (listed.items) |t| {
        try testing.expect(t.object.get("name").?.string.len > 0);
        try testing.expect(t.object.get("description").?.string.len > 0);
        try testing.expectEqualStrings("object", t.object.get("inputSchema").?.object.get("type").?.string);
    }
}

test "protocol-level failures map to JSON-RPC error codes" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    try testing.expectEqual(
        jsonrpc.code_method_not_found,
        try env.callExpectErrorCode(
            \\{"jsonrpc":"2.0","id":1,"method":"resources/list"}
        ),
    );
    try testing.expectEqual(jsonrpc.code_parse_error, try env.callExpectErrorCode("{not json"));
    // Batches were removed in MCP 2025-06-18.
    try testing.expectEqual(
        jsonrpc.code_invalid_request,
        try env.callExpectErrorCode(
            \\[{"jsonrpc":"2.0","id":1,"method":"ping"}]
        ),
    );

    // A parse error cannot echo an id; it must be null.
    const envelope = try env.call("{not json");
    try testing.expect(envelope.object.get("id").? == .null);
}

test "tools/call rejects malformed params with -32602" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const invalid = jsonrpc.code_invalid_params;
    try testing.expectEqual(invalid, try env.callExpectErrorCode(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call"}
    ));
    try testing.expectEqual(invalid, try env.callExpectErrorCode(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"arguments":{}}}
    ));
    try testing.expectEqual(invalid, try env.callExpectErrorCode(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":42}}
    ));
    try testing.expectEqual(invalid, try env.callExpectErrorCode(
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool"}}
    ));
}

test "tools/call wraps handler output in a text content block" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const result = try env.callExpectResult(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_grammar","arguments":{"query":"ならでは"}}}
    );
    const text = try toolText(result, false);
    const payload = try std.json.parseFromSliceLeaky(std.json.Value, env.arena(), text, .{});
    const matches = payload.object.get("results").?.array;
    try testing.expectEqual(@as(usize, 1), matches.items.len);
    try testing.expectEqualStrings("〜ならでは", matches.items[0].object.get("pattern").?.string);
}

test "tools/call surfaces domain errors as isError, not JSON-RPC errors" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const result = try env.callExpectResult(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_grammar","arguments":{"id":999}}}
    );
    const text = try toolText(result, true);
    try testing.expect(std.mem.indexOf(u8, text, "not found") != null);
}

test "tools/call turns database failures into an error outcome" {
    // A connection with no schema: every tool query fails inside DuckDB.
    var db = try db_mod.Db.open(":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handle(arena, &db,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_study_summary","arguments":{}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    const envelope = try std.json.parseFromSliceLeaky(std.json.Value, arena, res.body, .{});
    const result = envelope.object.get("result").?;
    try testing.expect(result.object.get("isError").?.bool);
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expect(std.mem.startsWith(u8, text, "database error:"));
}
