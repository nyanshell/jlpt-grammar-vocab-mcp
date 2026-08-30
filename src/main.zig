const std = @import("std");
const http = @import("http.zig");
const db_mod = @import("db.zig");

const seed_sql: [:0]const u8 = @embedFile("seed.sql");

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const env = init.environ_map;

    const secret = env.get("MCP_SECRET") orelse
        fatal("MCP_SECRET environment variable is required", .{});
    if (secret.len < 16)
        fatal("MCP_SECRET must be at least 16 characters (got {d})", .{secret.len});

    const port_str = env.get("PORT") orelse "8080";
    const port = std.fmt.parseInt(u16, port_str, 10) catch
        fatal("invalid PORT: {s}", .{port_str});
    const bind = env.get("BIND_ADDR") orelse "0.0.0.0";
    const db_path = env.get("DB_PATH") orelse "./data/jlpt.duckdb";

    if (std.fs.path.dirname(db_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(init.io, dir) catch |err|
            fatal("cannot create database directory {s}: {t}", .{ dir, err });
    }

    const db_path_z = try gpa.dupeSentinel(u8, db_path, 0);
    defer gpa.free(db_path_z);
    var db = db_mod.Db.open(db_path_z) catch
        fatal("cannot open database at {s}", .{db_path});
    defer db.close();
    db_mod.migrate(&db, seed_sql) catch
        fatal("migration failed: {s}", .{db.lastError()});

    std.debug.print("jlpt-mcp-server {s} — db: {s}\n", .{ @import("mcp.zig").server_version, db_path });
    try http.serve(init.io, gpa, &db, .{ .bind = bind, .port = port, .secret = secret });
}

test {
    _ = @import("db.zig");
    _ = @import("srs.zig");
    _ = @import("jsonrpc.zig");
    _ = @import("mcp.zig");
    _ = @import("http.zig");
    _ = @import("tools.zig");
}
