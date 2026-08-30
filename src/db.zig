//! Thin wrapper over the DuckDB C API.
//!
//! Uses the materialized value API (duckdb_value_varchar & co). It is marked
//! deprecated upstream but ships in v1.5.x; result sets here are tiny and the
//! wrapper isolates a future move to duckdb_fetch_chunk in this one file.

const std = @import("std");
const c = @import("duckdb_c");

pub const schema_sql: [:0]const u8 = @embedFile("schema.sql");

pub const DbError = error{DuckDb} || std.mem.Allocator.Error;

pub const Param = union(enum) {
    text: []const u8,
    int: i64,
    float: f64,
    nul,
};

/// A fully materialized result set. All cell values are arena-owned strings
/// (DuckDB stringifies every type, including dates and numbers); SQL NULL is
/// a null cell.
pub const Rows = struct {
    columns: []const []const u8,
    cells: []const ?[]const u8,
    row_count: usize,
    col_count: usize,

    pub const empty: Rows = .{ .columns = &.{}, .cells = &.{}, .row_count = 0, .col_count = 0 };

    pub fn colIndex(self: Rows, name: []const u8) ?usize {
        for (self.columns, 0..) |col_name, i| {
            if (std.mem.eql(u8, col_name, name)) return i;
        }
        return null;
    }

    pub fn get(self: Rows, row: usize, name: []const u8) ?[]const u8 {
        const ci = self.colIndex(name) orelse std.debug.panic("unknown column: {s}", .{name});
        return self.cells[row * self.col_count + ci];
    }

    pub fn getInt(self: Rows, row: usize, name: []const u8) ?i64 {
        const s = self.get(row, name) orelse return null;
        return std.fmt.parseInt(i64, s, 10) catch null;
    }

    pub fn getFloat(self: Rows, row: usize, name: []const u8) ?f64 {
        const s = self.get(row, name) orelse return null;
        return std.fmt.parseFloat(f64, s) catch null;
    }
};

pub const Db = struct {
    db: c.duckdb_database,
    conn: c.duckdb_connection,
    err_buf: [1024]u8,
    err_len: usize,

    pub fn open(path: [:0]const u8) DbError!Db {
        var db: c.duckdb_database = null;
        var err_msg: [*c]u8 = null;
        if (c.duckdb_open_ext(path.ptr, &db, null, &err_msg) != c.DuckDBSuccess) {
            if (err_msg != null) {
                std.debug.print("duckdb open failed: {s}\n", .{err_msg});
                c.duckdb_free(err_msg);
            }
            return error.DuckDb;
        }
        errdefer c.duckdb_close(&db);
        var conn: c.duckdb_connection = null;
        if (c.duckdb_connect(db, &conn) != c.DuckDBSuccess) return error.DuckDb;
        return .{ .db = db, .conn = conn, .err_buf = undefined, .err_len = 0 };
    }

    pub fn close(self: *Db) void {
        c.duckdb_disconnect(&self.conn);
        c.duckdb_close(&self.db);
    }

    pub fn lastError(self: *const Db) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    fn setError(self: *Db, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.err_len = n;
    }

    fn setErrorC(self: *Db, msg: [*c]const u8) void {
        self.setError(if (msg != null) std.mem.span(msg) else "unknown duckdb error");
    }

    /// Execute one or more statements, discarding any result rows.
    pub fn exec(self: *Db, sql: [:0]const u8) DbError!void {
        var result: c.duckdb_result = undefined;
        if (c.duckdb_query(self.conn, sql.ptr, &result) != c.DuckDBSuccess) {
            self.setErrorC(c.duckdb_result_error(&result));
            c.duckdb_destroy_result(&result);
            return error.DuckDb;
        }
        c.duckdb_destroy_result(&result);
    }

    /// Execute a single (optionally parameterized) statement and materialize
    /// the result into `arena`.
    pub fn query(self: *Db, arena: std.mem.Allocator, sql: []const u8, params: []const Param) DbError!Rows {
        const sql_z = try arena.dupeSentinel(u8, sql, 0);
        var result: c.duckdb_result = undefined;

        if (params.len == 0) {
            if (c.duckdb_query(self.conn, sql_z.ptr, &result) != c.DuckDBSuccess) {
                self.setErrorC(c.duckdb_result_error(&result));
                c.duckdb_destroy_result(&result);
                return error.DuckDb;
            }
        } else {
            var stmt: c.duckdb_prepared_statement = null;
            if (c.duckdb_prepare(self.conn, sql_z.ptr, &stmt) != c.DuckDBSuccess) {
                self.setErrorC(c.duckdb_prepare_error(stmt));
                c.duckdb_destroy_prepare(&stmt);
                return error.DuckDb;
            }
            defer c.duckdb_destroy_prepare(&stmt);

            for (params, 0..) |p, i| {
                const idx: c.idx_t = @intCast(i + 1);
                const state = switch (p) {
                    .text => |t| blk: {
                        const t_z = try arena.dupeSentinel(u8, t, 0);
                        break :blk c.duckdb_bind_varchar(stmt, idx, t_z.ptr);
                    },
                    .int => |v| c.duckdb_bind_int64(stmt, idx, v),
                    .float => |v| c.duckdb_bind_double(stmt, idx, v),
                    .nul => c.duckdb_bind_null(stmt, idx),
                };
                if (state != c.DuckDBSuccess) {
                    self.setError("failed to bind parameter");
                    return error.DuckDb;
                }
            }

            if (c.duckdb_execute_prepared(stmt, &result) != c.DuckDBSuccess) {
                self.setErrorC(c.duckdb_result_error(&result));
                c.duckdb_destroy_result(&result);
                return error.DuckDb;
            }
        }
        defer c.duckdb_destroy_result(&result);

        const col_count: usize = @intCast(c.duckdb_column_count(&result));
        const row_count: usize = @intCast(c.duckdb_row_count(&result));

        const columns = try arena.alloc([]const u8, col_count);
        for (columns, 0..) |*name, ci| {
            const c_name = c.duckdb_column_name(&result, @intCast(ci));
            name.* = try arena.dupe(u8, if (c_name != null) std.mem.span(c_name) else "");
        }

        const cells = try arena.alloc(?[]const u8, col_count * row_count);
        for (0..row_count) |ri| {
            for (0..col_count) |ci| {
                const cell = &cells[ri * col_count + ci];
                if (c.duckdb_value_is_null(&result, @intCast(ci), @intCast(ri))) {
                    cell.* = null;
                    continue;
                }
                const v = c.duckdb_value_varchar(&result, @intCast(ci), @intCast(ri));
                if (v == null) {
                    cell.* = null;
                    continue;
                }
                cell.* = arena.dupe(u8, std.mem.span(v)) catch |err| {
                    c.duckdb_free(v);
                    return err;
                };
                c.duckdb_free(v);
            }
        }

        return .{ .columns = columns, .cells = cells, .row_count = row_count, .col_count = col_count };
    }
};

/// Create the schema (idempotent) and load the seed exactly once, inside a
/// transaction, when the grammar table is empty.
pub fn migrate(db: *Db, seed: [:0]const u8) DbError!void {
    try db.exec(schema_sql);

    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const rows = try db.query(fba.allocator(), "SELECT count(*) AS n FROM grammar_points", &.{});
    const n = rows.getInt(0, "n") orelse 0;
    if (n == 0) {
        try db.exec("BEGIN TRANSACTION");
        errdefer db.exec("ROLLBACK") catch {};
        try db.exec(seed);
        try db.exec("COMMIT");
    }
}

test "schema creates and round-trips data" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec(schema_sql);
    // Idempotency: running the schema twice must not fail.
    try db.exec(schema_sql);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try db.query(
        arena,
        "INSERT INTO grammar_points (id, pattern, meaning) VALUES (?, ?, ?)",
        &.{ .{ .int = 1 }, .{ .text = "〜んがために" }, .{ .text = "in order to (literary)" } },
    );

    const rows = try db.query(
        arena,
        "SELECT id, pattern, reading FROM grammar_points WHERE meaning ILIKE ?",
        &.{.{ .text = "%order%" }},
    );
    try std.testing.expectEqual(@as(usize, 1), rows.row_count);
    try std.testing.expectEqual(@as(i64, 1), rows.getInt(0, "id").?);
    try std.testing.expectEqualStrings("〜んがために", rows.get(0, "pattern").?);
    try std.testing.expect(rows.get(0, "reading") == null);
}

test "sequence ids start above seed range" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec(schema_sql);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try db.query(
        arena,
        "INSERT INTO grammar_points (pattern, meaning) VALUES ('x', 'y') RETURNING id",
        &.{},
    );
    try std.testing.expect(rows.getInt(0, "id").? >= 10001);
}

test "sql errors carry a message" {
    var db = try Db.open(":memory:");
    defer db.close();
    try std.testing.expectError(error.DuckDb, db.exec("SELECT nonsense FROM missing_table"));
    try std.testing.expect(db.lastError().len > 0);
}

test "param binding round-trips int, float, text, and null" {
    var db = try Db.open(":memory:");
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try db.query(arena, "SELECT ? AS i, ? AS f, ? AS t, ? AS n", &.{
        .{ .int = -42 },
        .{ .float = 2.5 },
        .{ .text = "こんにちは" },
        .nul,
    });
    try std.testing.expectEqual(@as(i64, -42), rows.getInt(0, "i").?);
    try std.testing.expectEqual(@as(f64, 2.5), rows.getFloat(0, "f").?);
    try std.testing.expectEqualStrings("こんにちは", rows.get(0, "t").?);
    try std.testing.expect(rows.get(0, "n") == null);
}

test "colIndex misses return null; getInt on non-numeric text returns null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try Db.open(":memory:");
    defer db.close();
    const rows = try db.query(arena, "SELECT 'abc' AS s", &.{});
    try std.testing.expect(rows.colIndex("missing") == null);
    try std.testing.expect(rows.getInt(0, "s") == null);
    try std.testing.expect(rows.getFloat(0, "s") == null);
    try std.testing.expectEqual(@as(usize, 0), Rows.empty.row_count);
}

test "migrate seeds an empty database exactly once" {
    var db = try Db.open(":memory:");
    defer db.close();
    const seed: [:0]const u8 =
        \\INSERT INTO grammar_points (id, pattern, meaning) VALUES (1, 'x', 'y');
    ;
    try migrate(&db, seed);
    // A second migrate must be a no-op: the table is no longer empty.
    try migrate(&db, seed);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try db.query(arena_state.allocator(), "SELECT count(*) AS n FROM grammar_points", &.{});
    try std.testing.expectEqual(@as(i64, 1), rows.getInt(0, "n").?);
}

test "migrate rolls back a failing seed" {
    var db = try Db.open(":memory:");
    defer db.close();
    const bad_seed: [:0]const u8 =
        \\INSERT INTO grammar_points (id, pattern, meaning) VALUES (1, 'x', 'y');
        \\INSERT INTO no_such_table VALUES (1);
    ;
    try std.testing.expectError(error.DuckDb, migrate(&db, bad_seed));

    // The partial insert must not survive; a later migrate can still seed.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try db.query(arena_state.allocator(), "SELECT count(*) AS n FROM grammar_points", &.{});
    try std.testing.expectEqual(@as(i64, 0), rows.getInt(0, "n").?);
}
