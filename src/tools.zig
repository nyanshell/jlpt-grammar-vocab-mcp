//! MCP tool registry and handlers.
//!
//! Handlers return `Outcome.ok` with a raw JSON payload, or `Outcome.err`
//! with a human-readable message (surfaced as isError:true). `error.DuckDb`
//! escapes to the dispatcher, which turns it into an error outcome with the
//! database's message.

const std = @import("std");
const db_mod = @import("db.zig");
const srs = @import("srs.zig");

pub const Ctx = struct {
    arena: std.mem.Allocator,
    db: *db_mod.Db,
};

pub const Outcome = union(enum) {
    ok: []const u8,
    err: []const u8,
};

pub const HandlerError = error{ OutOfMemory, DuckDb };
pub const Handler = *const fn (ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome;

pub const Tool = struct {
    name: []const u8,
    /// Must be JSON-safe as written (no characters needing escaping).
    description: []const u8,
    /// Raw JSON schema object.
    input_schema: []const u8,
    handler: Handler,
};

pub const registry = [_]Tool{
    .{
        .name = "search_grammar",
        .description = "Search JLPT N1 grammar points by pattern, reading, meaning, or usage notes. Returns matches with the user's learning status.",
        .input_schema =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Text to search for, in Japanese or English"},"limit":{"type":"integer","default":10}},"required":["query"]}
        ,
        .handler = searchGrammar,
    },
    .{
        .name = "get_grammar",
        .description = "Get one grammar point in full: formation, nuance, register, example sentences, and the user's spaced-repetition state.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"integer","description":"Grammar point id"}},"required":["id"]}
        ,
        .handler = getGrammar,
    },
    .{
        .name = "list_grammar",
        .description = "List grammar points, optionally filtered by learning status (new, learning, review, mastered). Paginated.",
        .input_schema =
        \\{"type":"object","properties":{"status":{"type":"string","enum":["new","learning","review","mastered"]},"offset":{"type":"integer","default":0},"limit":{"type":"integer","default":20}}}
        ,
        .handler = listGrammar,
    },
    .{
        .name = "search_vocab",
        .description = "Search N1 vocabulary by word, reading, or meaning. Returns matches with the user's learning status.",
        .input_schema =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Text to search for, in Japanese or English"},"limit":{"type":"integer","default":10}},"required":["query"]}
        ,
        .handler = searchVocab,
    },
    .{
        .name = "list_vocab",
        .description = "List vocabulary words, optionally filtered by learning status (new, learning, review, mastered). Paginated.",
        .input_schema =
        \\{"type":"object","properties":{"status":{"type":"string","enum":["new","learning","review","mastered"]},"offset":{"type":"integer","default":0},"limit":{"type":"integer","default":20}}}
        ,
        .handler = listVocab,
    },
    .{
        .name = "add_grammar",
        .description = "Add a new grammar point to the study database.",
        .input_schema =
        \\{"type":"object","properties":{"pattern":{"type":"string"},"meaning":{"type":"string"},"reading":{"type":"string"},"formation":{"type":"string"},"nuance":{"type":"string"},"register":{"type":"string"},"level":{"type":"string","default":"N1"}},"required":["pattern","meaning"]}
        ,
        .handler = addGrammar,
    },
    .{
        .name = "update_grammar",
        .description = "Update fields of an existing grammar point. Only the provided fields change.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"integer"},"pattern":{"type":"string"},"meaning":{"type":"string"},"reading":{"type":"string"},"formation":{"type":"string"},"nuance":{"type":"string"},"register":{"type":"string"},"level":{"type":"string"}},"required":["id"]}
        ,
        .handler = updateGrammar,
    },
    .{
        .name = "add_example",
        .description = "Add an example sentence to a grammar point. Provide the full-kana reading when possible.",
        .input_schema =
        \\{"type":"object","properties":{"grammar_id":{"type":"integer"},"japanese":{"type":"string"},"english":{"type":"string"},"reading":{"type":"string","description":"Full-kana reading of the sentence"}},"required":["grammar_id","japanese","english"]}
        ,
        .handler = addExample,
    },
    .{
        .name = "add_vocab",
        .description = "Add a vocabulary word to the study database.",
        .input_schema =
        \\{"type":"object","properties":{"word":{"type":"string"},"reading":{"type":"string"},"meaning":{"type":"string"},"part_of_speech":{"type":"string"},"level":{"type":"string","default":"N1"}},"required":["word","reading","meaning"]}
        ,
        .handler = addVocab,
    },
    .{
        .name = "update_vocab",
        .description = "Update fields of an existing vocabulary word. Only the provided fields change.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"integer"},"word":{"type":"string"},"reading":{"type":"string"},"meaning":{"type":"string"},"part_of_speech":{"type":"string"},"level":{"type":"string"}},"required":["id"]}
        ,
        .handler = updateVocab,
    },
    .{
        .name = "get_due_reviews",
        .description = "Get items due for spaced-repetition review today (ordered by due date), plus a few never-studied items. Optionally restrict to grammar or vocab only. Use get_grammar for full details and examples.",
        .input_schema =
        \\{"type":"object","properties":{"item_type":{"type":"string","enum":["grammar","vocab"],"description":"Restrict to one item type"},"limit":{"type":"integer","default":20},"include_new":{"type":"boolean","default":true},"new_limit":{"type":"integer","default":5}}}
        ,
        .handler = getDueReviews,
    },
    .{
        .name = "record_review",
        .description = "Record the result of reviewing one item and reschedule it with SM-2. quality: 0-2 = failed recall (resets progress), 3 = recalled with difficulty, 4 = recalled correctly, 5 = recalled easily.",
        .input_schema =
        \\{"type":"object","properties":{"item_type":{"type":"string","enum":["grammar","vocab"]},"item_id":{"type":"integer"},"quality":{"type":"integer","minimum":0,"maximum":5}},"required":["item_type","item_id","quality"]}
        ,
        .handler = recordReview,
    },
    .{
        .name = "get_review_history",
        .description = "Get past review results (the user's quiz and flashcard answer history), newest first. Filter by item type, a single item, a lookback window, or max_quality (e.g. 2 to see only failed recalls). Use this to report how recent sessions went and to find items worth re-drilling.",
        .input_schema =
        \\{"type":"object","properties":{"item_type":{"type":"string","enum":["grammar","vocab"]},"item_id":{"type":"integer","description":"History for one item; requires item_type"},"days":{"type":"integer","default":7,"description":"Lookback window in days; 1 = today only"},"max_quality":{"type":"integer","minimum":0,"maximum":5,"description":"Only reviews with quality at or below this"},"limit":{"type":"integer","default":50}}}
        ,
        .handler = getReviewHistory,
    },
    .{
        .name = "get_study_summary",
        .description = "Get overall study progress: item counts by learning status, reviews done today and this week, and how many items are due.",
        .input_schema =
        \\{"type":"object","properties":{}}
        ,
        .handler = getStudySummary,
    },
};

pub fn find(name: []const u8) ?*const Tool {
    for (&registry) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Comptime-rendered `{"tools":[...]}` result for tools/list.
pub const list_json = blk: {
    @setEvalBranchQuota(100_000);
    var s: []const u8 = "{\"tools\":[";
    for (registry, 0..) |t, i| {
        if (i != 0) s = s ++ ",";
        s = s ++ "{\"name\":\"" ++ t.name ++ "\",\"description\":\"" ++ t.description ++
            "\",\"inputSchema\":" ++ t.input_schema ++ "}";
    }
    break :blk s ++ "]}";
};

// --- argument helpers ---------------------------------------------------

fn argValue(args: ?std.json.Value, name: []const u8) ?std.json.Value {
    const a = args orelse return null;
    if (a != .object) return null;
    return a.object.get(name);
}

fn argStr(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return switch (argValue(args, name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn argInt(args: ?std.json.Value, name: []const u8) ?i64 {
    return switch (argValue(args, name) orelse return null) {
        .integer => |v| v,
        .float => |v| if (v == @trunc(v)) @intFromFloat(v) else null,
        else => null,
    };
}

fn argBool(args: ?std.json.Value, name: []const u8) ?bool {
    return switch (argValue(args, name) orelse return null) {
        .bool => |v| v,
        else => null,
    };
}

fn clampLimit(v: ?i64, default: i64) i64 {
    const n = v orelse default;
    return @max(1, @min(n, 100));
}

// --- JSON output helpers ------------------------------------------------

const Json = std.json.Stringify;

const Col = struct {
    name: []const u8,
    kind: enum { text, int, float } = .text,
};

fn writeCell(s: *Json, rows: db_mod.Rows, ri: usize, col: Col) !void {
    const cell = rows.get(ri, col.name) orelse return s.write(null);
    switch (col.kind) {
        .text => try s.write(cell),
        .int => {
            if (std.fmt.parseInt(i64, cell, 10)) |v| try s.write(v) else |_| try s.write(cell);
        },
        .float => {
            if (std.fmt.parseFloat(f64, cell)) |v| try s.write(v) else |_| try s.write(cell);
        },
    }
}

fn writeRowObject(s: *Json, rows: db_mod.Rows, ri: usize, cols: []const Col) !void {
    try s.beginObject();
    for (cols) |col| {
        try s.objectField(col.name);
        try writeCell(s, rows, ri, col);
    }
    try s.endObject();
}

fn writeRowsArray(s: *Json, rows: db_mod.Rows, cols: []const Col) !void {
    try s.beginArray();
    for (0..rows.row_count) |ri| try writeRowObject(s, rows, ri, cols);
    try s.endArray();
}

const Payload = struct {
    aw: std.Io.Writer.Allocating,
    s: Json,

    fn init(p: *Payload, arena: std.mem.Allocator) void {
        p.aw = .init(arena);
        p.s = .{ .writer = &p.aw.writer, .options = .{} };
    }

    fn finish(p: *Payload) Outcome {
        return .{ .ok = p.aw.written() };
    }
};

// --- grammar tools ------------------------------------------------------

const grammar_summary_cols = [_]Col{
    .{ .name = "id", .kind = .int },
    .{ .name = "pattern" },
    .{ .name = "reading" },
    .{ .name = "meaning" },
    .{ .name = "status" },
};

fn searchGrammar(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const query = argStr(args, "query") orelse return .{ .err = "missing required argument: query" };
    const limit = clampLimit(argInt(args, "limit"), 10);
    const like = try std.fmt.allocPrint(ctx.arena, "%{s}%", .{query});

    const rows = try ctx.db.query(ctx.arena,
        \\SELECT g.id, g.pattern, g.reading, g.meaning, coalesce(ls.status, 'new') AS status
        \\FROM grammar_points g
        \\LEFT JOIN learning_status ls ON ls.item_type = 'grammar' AND ls.item_id = g.id
        \\WHERE g.pattern ILIKE ? OR coalesce(g.reading, '') ILIKE ?
        \\   OR g.meaning ILIKE ? OR coalesce(g.nuance, '') ILIKE ?
        \\ORDER BY g.id
        \\LIMIT ?
    , &.{ .{ .text = like }, .{ .text = like }, .{ .text = like }, .{ .text = like }, .{ .int = limit } });

    var p: Payload = undefined;
    p.init(ctx.arena);
    writeSearchGrammar(&p.s, rows) catch return error.OutOfMemory;
    return p.finish();
}

fn writeSearchGrammar(s: *Json, rows: db_mod.Rows) !void {
    try s.beginObject();
    try s.objectField("results");
    try writeRowsArray(s, rows, &grammar_summary_cols);
    try s.endObject();
}

fn getGrammar(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const id = argInt(args, "id") orelse return .{ .err = "missing required argument: id" };

    const rows = try ctx.db.query(ctx.arena,
        \\SELECT g.id, g.level, g.pattern, g.reading, g.meaning, g.formation, g.nuance, g.register,
        \\       coalesce(ls.status, 'new') AS status, ls.ease_factor, ls.interval_days,
        \\       ls.repetitions, ls.due_date, ls.last_reviewed_at
        \\FROM grammar_points g
        \\LEFT JOIN learning_status ls ON ls.item_type = 'grammar' AND ls.item_id = g.id
        \\WHERE g.id = ?
    , &.{.{ .int = id }});
    if (rows.row_count == 0)
        return .{ .err = try std.fmt.allocPrint(ctx.arena, "grammar point {d} not found", .{id}) };

    const examples = try ctx.db.query(ctx.arena,
        \\SELECT id, japanese, reading, english FROM grammar_examples
        \\WHERE grammar_id = ? ORDER BY id
    , &.{.{ .int = id }});

    var p: Payload = undefined;
    p.init(ctx.arena);
    writeGetGrammar(&p.s, rows, examples) catch return error.OutOfMemory;
    return p.finish();
}

fn writeGetGrammar(s: *Json, rows: db_mod.Rows, examples: db_mod.Rows) !void {
    try s.beginObject();
    const fields = [_]Col{
        .{ .name = "id", .kind = .int },
        .{ .name = "level" },
        .{ .name = "pattern" },
        .{ .name = "reading" },
        .{ .name = "meaning" },
        .{ .name = "formation" },
        .{ .name = "nuance" },
        .{ .name = "register" },
        .{ .name = "status" },
    };
    for (fields) |col| {
        try s.objectField(col.name);
        try writeCell(s, rows, 0, col);
    }
    try s.objectField("srs");
    if (rows.get(0, "ease_factor") == null) {
        try s.write(null);
    } else {
        const srs_cols = [_]Col{
            .{ .name = "ease_factor", .kind = .float },
            .{ .name = "interval_days", .kind = .int },
            .{ .name = "repetitions", .kind = .int },
            .{ .name = "due_date" },
            .{ .name = "last_reviewed_at" },
        };
        try writeRowObject(s, rows, 0, &srs_cols);
    }
    try s.objectField("examples");
    const example_cols = [_]Col{
        .{ .name = "id", .kind = .int },
        .{ .name = "japanese" },
        .{ .name = "reading" },
        .{ .name = "english" },
    };
    try writeRowsArray(s, examples, &example_cols);
    try s.endObject();
}

const valid_statuses = [_][]const u8{ "new", "learning", "review", "mastered" };

fn listGrammar(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const offset = @max(0, argInt(args, "offset") orelse 0);
    const limit = clampLimit(argInt(args, "limit"), 20);
    const status = argStr(args, "status");
    if (status) |st| {
        var ok = false;
        for (valid_statuses) |v| ok = ok or std.mem.eql(u8, v, st);
        if (!ok) return .{ .err = "invalid status: must be new, learning, review, or mastered" };
    }

    const filter = status orelse "%";
    const total_rows = try ctx.db.query(ctx.arena,
        \\SELECT count(*) AS n
        \\FROM grammar_points g
        \\LEFT JOIN learning_status ls ON ls.item_type = 'grammar' AND ls.item_id = g.id
        \\WHERE coalesce(ls.status, 'new') LIKE ?
    , &.{.{ .text = filter }});
    const total = total_rows.getInt(0, "n") orelse 0;

    const rows = try ctx.db.query(ctx.arena,
        \\SELECT g.id, g.pattern, g.reading, g.meaning, coalesce(ls.status, 'new') AS status
        \\FROM grammar_points g
        \\LEFT JOIN learning_status ls ON ls.item_type = 'grammar' AND ls.item_id = g.id
        \\WHERE coalesce(ls.status, 'new') LIKE ?
        \\ORDER BY g.id
        \\LIMIT ? OFFSET ?
    , &.{ .{ .text = filter }, .{ .int = limit }, .{ .int = offset } });

    var p: Payload = undefined;
    p.init(ctx.arena);
    writeListGrammar(&p.s, total, offset, rows) catch return error.OutOfMemory;
    return p.finish();
}

fn writeListGrammar(s: *Json, total: i64, offset: i64, rows: db_mod.Rows) !void {
    try s.beginObject();
    try s.objectField("total");
    try s.write(total);
    try s.objectField("offset");
    try s.write(offset);
    try s.objectField("items");
    try writeRowsArray(s, rows, &grammar_summary_cols);
    try s.endObject();
}

// --- vocab tools --------------------------------------------------------

fn searchVocab(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const query = argStr(args, "query") orelse return .{ .err = "missing required argument: query" };
    const limit = clampLimit(argInt(args, "limit"), 10);
    const like = try std.fmt.allocPrint(ctx.arena, "%{s}%", .{query});

    const rows = try ctx.db.query(ctx.arena,
        \\SELECT v.id, v.word, v.reading, v.meaning, v.part_of_speech, coalesce(ls.status, 'new') AS status
        \\FROM vocab v
        \\LEFT JOIN learning_status ls ON ls.item_type = 'vocab' AND ls.item_id = v.id
        \\WHERE v.word ILIKE ? OR v.reading ILIKE ? OR v.meaning ILIKE ?
        \\ORDER BY v.id
        \\LIMIT ?
    , &.{ .{ .text = like }, .{ .text = like }, .{ .text = like }, .{ .int = limit } });

    var p: Payload = undefined;
    p.init(ctx.arena);
    writeSearchVocab(&p.s, rows) catch return error.OutOfMemory;
    return p.finish();
}

fn writeSearchVocab(s: *Json, rows: db_mod.Rows) !void {
    const cols = [_]Col{
        .{ .name = "id", .kind = .int },
        .{ .name = "word" },
        .{ .name = "reading" },
        .{ .name = "meaning" },
        .{ .name = "part_of_speech" },
        .{ .name = "status" },
    };
    try s.beginObject();
    try s.objectField("results");
    try writeRowsArray(s, rows, &cols);
    try s.endObject();
}

fn listVocab(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const offset = @max(0, argInt(args, "offset") orelse 0);
    const limit = clampLimit(argInt(args, "limit"), 20);
    const status = argStr(args, "status");
    if (status) |st| {
        var ok = false;
        for (valid_statuses) |v| ok = ok or std.mem.eql(u8, v, st);
        if (!ok) return .{ .err = "invalid status: must be new, learning, review, or mastered" };
    }

    const filter = status orelse "%";
    const total_rows = try ctx.db.query(ctx.arena,
        \\SELECT count(*) AS n
        \\FROM vocab v
        \\LEFT JOIN learning_status ls ON ls.item_type = 'vocab' AND ls.item_id = v.id
        \\WHERE coalesce(ls.status, 'new') LIKE ?
    , &.{.{ .text = filter }});
    const total = total_rows.getInt(0, "n") orelse 0;

    const rows = try ctx.db.query(ctx.arena,
        \\SELECT v.id, v.word, v.reading, v.meaning, v.part_of_speech, coalesce(ls.status, 'new') AS status
        \\FROM vocab v
        \\LEFT JOIN learning_status ls ON ls.item_type = 'vocab' AND ls.item_id = v.id
        \\WHERE coalesce(ls.status, 'new') LIKE ?
        \\ORDER BY v.id
        \\LIMIT ? OFFSET ?
    , &.{ .{ .text = filter }, .{ .int = limit }, .{ .int = offset } });

    var p: Payload = undefined;
    p.init(ctx.arena);
    writeListVocab(&p.s, total, offset, rows) catch return error.OutOfMemory;
    return p.finish();
}

fn writeListVocab(s: *Json, total: i64, offset: i64, rows: db_mod.Rows) !void {
    const cols = [_]Col{
        .{ .name = "id", .kind = .int },
        .{ .name = "word" },
        .{ .name = "reading" },
        .{ .name = "meaning" },
        .{ .name = "part_of_speech" },
        .{ .name = "status" },
    };
    try s.beginObject();
    try s.objectField("total");
    try s.write(total);
    try s.objectField("offset");
    try s.write(offset);
    try s.objectField("items");
    try writeRowsArray(s, rows, &cols);
    try s.endObject();
}

// --- content editing tools ----------------------------------------------

fn textOrNull(args: ?std.json.Value, name: []const u8) db_mod.Param {
    if (argStr(args, name)) |v| return .{ .text = v };
    return .nul;
}

fn idPayload(ctx: *Ctx, rows: db_mod.Rows) HandlerError!Outcome {
    const id = rows.getInt(0, "id") orelse return .{ .err = "insert returned no id" };
    return .{ .ok = try std.fmt.allocPrint(ctx.arena, "{{\"id\":{d}}}", .{id}) };
}

fn addGrammar(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const pattern = argStr(args, "pattern") orelse return .{ .err = "missing required argument: pattern" };
    const meaning = argStr(args, "meaning") orelse return .{ .err = "missing required argument: meaning" };

    const rows = try ctx.db.query(ctx.arena,
        \\INSERT INTO grammar_points (pattern, meaning, reading, formation, nuance, register, level)
        \\VALUES (?, ?, ?, ?, ?, ?, coalesce(?, 'N1'))
        \\RETURNING id
    , &.{
        .{ .text = pattern },
        .{ .text = meaning },
        textOrNull(args, "reading"),
        textOrNull(args, "formation"),
        textOrNull(args, "nuance"),
        textOrNull(args, "register"),
        textOrNull(args, "level"),
    });
    return idPayload(ctx, rows);
}

fn addExample(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const grammar_id = argInt(args, "grammar_id") orelse return .{ .err = "missing required argument: grammar_id" };
    const japanese = argStr(args, "japanese") orelse return .{ .err = "missing required argument: japanese" };
    const english = argStr(args, "english") orelse return .{ .err = "missing required argument: english" };

    const exists = try ctx.db.query(ctx.arena, "SELECT 1 FROM grammar_points WHERE id = ?", &.{.{ .int = grammar_id }});
    if (exists.row_count == 0)
        return .{ .err = try std.fmt.allocPrint(ctx.arena, "grammar point {d} not found", .{grammar_id}) };

    const rows = try ctx.db.query(ctx.arena,
        \\INSERT INTO grammar_examples (grammar_id, japanese, english, reading)
        \\VALUES (?, ?, ?, ?)
        \\RETURNING id
    , &.{
        .{ .int = grammar_id },
        .{ .text = japanese },
        .{ .text = english },
        textOrNull(args, "reading"),
    });
    return idPayload(ctx, rows);
}

fn addVocab(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const word = argStr(args, "word") orelse return .{ .err = "missing required argument: word" };
    const reading = argStr(args, "reading") orelse return .{ .err = "missing required argument: reading" };
    const meaning = argStr(args, "meaning") orelse return .{ .err = "missing required argument: meaning" };

    const rows = try ctx.db.query(ctx.arena,
        \\INSERT INTO vocab (word, reading, meaning, part_of_speech, level)
        \\VALUES (?, ?, ?, ?, coalesce(?, 'N1'))
        \\RETURNING id
    , &.{
        .{ .text = word },
        .{ .text = reading },
        .{ .text = meaning },
        textOrNull(args, "part_of_speech"),
        textOrNull(args, "level"),
    });
    return idPayload(ctx, rows);
}

/// Shared implementation for update_grammar / update_vocab: builds
/// `UPDATE <table> SET f = ?, ... WHERE id = ? RETURNING id` from the
/// provided whitelisted fields.
fn updateRow(
    ctx: *Ctx,
    args: ?std.json.Value,
    comptime table: []const u8,
    comptime fields: []const []const u8,
) HandlerError!Outcome {
    const id = argInt(args, "id") orelse return .{ .err = "missing required argument: id" };

    var set_clauses: std.ArrayList(u8) = .empty;
    var params: std.ArrayList(db_mod.Param) = .empty;
    inline for (fields) |field| {
        if (argStr(args, field)) |v| {
            if (params.items.len != 0) try set_clauses.appendSlice(ctx.arena, ", ");
            try set_clauses.appendSlice(ctx.arena, field ++ " = ?");
            try params.append(ctx.arena, .{ .text = v });
        }
    }
    if (params.items.len == 0) return .{ .err = "no fields to update" };
    try params.append(ctx.arena, .{ .int = id });

    const sql = try std.fmt.allocPrint(
        ctx.arena,
        "UPDATE " ++ table ++ " SET {s} WHERE id = ? RETURNING id",
        .{set_clauses.items},
    );
    const rows = try ctx.db.query(ctx.arena, sql, params.items);
    if (rows.row_count == 0)
        return .{ .err = try std.fmt.allocPrint(ctx.arena, table ++ " id {d} not found", .{id}) };
    return .{ .ok = "{\"updated\":true}" };
}

fn updateGrammar(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    return updateRow(ctx, args, "grammar_points", &.{ "pattern", "meaning", "reading", "formation", "nuance", "register", "level" });
}

fn updateVocab(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    return updateRow(ctx, args, "vocab", &.{ "word", "reading", "meaning", "part_of_speech", "level" });
}

// --- SRS tools ----------------------------------------------------------

const review_item_cols = [_]Col{
    .{ .name = "item_type" },
    .{ .name = "item_id", .kind = .int },
    .{ .name = "front" },
    .{ .name = "reading" },
    .{ .name = "meaning" },
};

fn getDueReviews(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const limit = clampLimit(argInt(args, "limit"), 20);
    const include_new = argBool(args, "include_new") orelse true;
    const new_limit = clampLimit(argInt(args, "new_limit"), 5);
    const type_filter = argStr(args, "item_type") orelse "%";
    if (argStr(args, "item_type")) |t| {
        if (!std.mem.eql(u8, t, "grammar") and !std.mem.eql(u8, t, "vocab"))
            return .{ .err = "item_type must be grammar or vocab" };
    }

    const due = try ctx.db.query(ctx.arena,
        \\SELECT * FROM (
        \\  SELECT 'grammar' AS item_type, g.id AS item_id, g.pattern AS front, g.reading, g.meaning,
        \\         ls.due_date, ls.interval_days, ls.repetitions
        \\  FROM learning_status ls
        \\  JOIN grammar_points g ON g.id = ls.item_id AND ls.item_type = 'grammar'
        \\  UNION ALL
        \\  SELECT 'vocab', v.id, v.word, v.reading, v.meaning, ls.due_date, ls.interval_days, ls.repetitions
        \\  FROM learning_status ls
        \\  JOIN vocab v ON v.id = ls.item_id AND ls.item_type = 'vocab'
        \\)
        \\WHERE due_date <= CURRENT_DATE AND item_type LIKE ?
        \\ORDER BY due_date, item_type, item_id
        \\LIMIT ?
    , &.{ .{ .text = type_filter }, .{ .int = limit } });

    const fresh = if (include_new) try ctx.db.query(ctx.arena,
        \\SELECT * FROM (
        \\  SELECT 'grammar' AS item_type, g.id AS item_id, g.pattern AS front, g.reading, g.meaning
        \\  FROM grammar_points g
        \\  LEFT JOIN learning_status ls ON ls.item_type = 'grammar' AND ls.item_id = g.id
        \\  WHERE ls.item_id IS NULL
        \\  UNION ALL
        \\  SELECT 'vocab', v.id, v.word, v.reading, v.meaning
        \\  FROM vocab v
        \\  LEFT JOIN learning_status ls ON ls.item_type = 'vocab' AND ls.item_id = v.id
        \\  WHERE ls.item_id IS NULL
        \\)
        \\WHERE item_type LIKE ?
        \\ORDER BY item_type, item_id
        \\LIMIT ?
    , &.{ .{ .text = type_filter }, .{ .int = new_limit } }) else db_mod.Rows.empty;

    var p: Payload = undefined;
    p.init(ctx.arena);
    writeDueReviews(&p.s, due, fresh) catch return error.OutOfMemory;
    return p.finish();
}

fn writeDueReviews(s: *Json, due: db_mod.Rows, fresh: db_mod.Rows) !void {
    const due_cols = review_item_cols ++ [_]Col{
        .{ .name = "due_date" },
        .{ .name = "interval_days", .kind = .int },
        .{ .name = "repetitions", .kind = .int },
    };
    try s.beginObject();
    try s.objectField("due");
    try writeRowsArray(s, due, &due_cols);
    try s.objectField("new");
    try writeRowsArray(s, fresh, &review_item_cols);
    try s.endObject();
}

fn recordReview(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const item_type = argStr(args, "item_type") orelse return .{ .err = "missing required argument: item_type" };
    const item_id = argInt(args, "item_id") orelse return .{ .err = "missing required argument: item_id" };
    const quality_i = argInt(args, "quality") orelse return .{ .err = "missing required argument: quality" };

    const is_grammar = std.mem.eql(u8, item_type, "grammar");
    if (!is_grammar and !std.mem.eql(u8, item_type, "vocab"))
        return .{ .err = "item_type must be grammar or vocab" };
    if (quality_i < 0 or quality_i > 5)
        return .{ .err = "quality must be between 0 and 5" };
    const quality: u3 = @intCast(quality_i);

    const exists = try ctx.db.query(
        ctx.arena,
        if (is_grammar) "SELECT 1 FROM grammar_points WHERE id = ?" else "SELECT 1 FROM vocab WHERE id = ?",
        &.{.{ .int = item_id }},
    );
    if (exists.row_count == 0)
        return .{ .err = try std.fmt.allocPrint(ctx.arena, "{s} item {d} not found", .{ item_type, item_id }) };

    const prev = try ctx.db.query(ctx.arena,
        \\SELECT ease_factor, interval_days, repetitions FROM learning_status
        \\WHERE item_type = ? AND item_id = ?
    , &.{ .{ .text = item_type }, .{ .int = item_id } });

    const state: srs.State = if (prev.row_count == 0) .fresh else .{
        .ease_factor = prev.getFloat(0, "ease_factor") orelse 2.5,
        .interval_days = @intCast(prev.getInt(0, "interval_days") orelse 0),
        .repetitions = @intCast(prev.getInt(0, "repetitions") orelse 0),
    };
    const next = srs.apply(state, quality);
    const status = srs.status(next, quality);

    try ctx.db.exec("BEGIN TRANSACTION");
    errdefer ctx.db.exec("ROLLBACK") catch {};
    const upserted = try ctx.db.query(ctx.arena,
        \\INSERT INTO learning_status
        \\  (item_type, item_id, ease_factor, interval_days, repetitions, due_date, status, last_reviewed_at)
        \\VALUES (?, ?, ?, ?, ?, CURRENT_DATE + CAST(? AS INTEGER), ?, now())
        \\ON CONFLICT (item_type, item_id) DO UPDATE SET
        \\  ease_factor = excluded.ease_factor,
        \\  interval_days = excluded.interval_days,
        \\  repetitions = excluded.repetitions,
        \\  due_date = excluded.due_date,
        \\  status = excluded.status,
        \\  last_reviewed_at = excluded.last_reviewed_at
        \\RETURNING due_date
    , &.{
        .{ .text = item_type },
        .{ .int = item_id },
        .{ .float = next.ease_factor },
        .{ .int = next.interval_days },
        .{ .int = next.repetitions },
        .{ .int = next.interval_days },
        .{ .text = status },
    });
    _ = try ctx.db.query(ctx.arena,
        \\INSERT INTO review_history (item_type, item_id, quality, interval_after, ease_after)
        \\VALUES (?, ?, ?, ?, ?)
    , &.{
        .{ .text = item_type },
        .{ .int = item_id },
        .{ .int = quality_i },
        .{ .int = next.interval_days },
        .{ .float = next.ease_factor },
    });
    try ctx.db.exec("COMMIT");

    var p: Payload = undefined;
    p.init(ctx.arena);
    writeReviewResult(&p.s, item_type, item_id, quality_i, next, status, upserted.get(0, "due_date")) catch
        return error.OutOfMemory;
    return p.finish();
}

fn writeReviewResult(
    s: *Json,
    item_type: []const u8,
    item_id: i64,
    quality: i64,
    next: srs.State,
    status: []const u8,
    due_date: ?[]const u8,
) !void {
    try s.beginObject();
    try s.objectField("item_type");
    try s.write(item_type);
    try s.objectField("item_id");
    try s.write(item_id);
    try s.objectField("quality");
    try s.write(quality);
    try s.objectField("ease_factor");
    try s.write(next.ease_factor);
    try s.objectField("interval_days");
    try s.write(next.interval_days);
    try s.objectField("repetitions");
    try s.write(next.repetitions);
    try s.objectField("due_date");
    try s.write(due_date);
    try s.objectField("status");
    try s.write(status);
    try s.endObject();
}

fn getReviewHistory(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    const type_filter = argStr(args, "item_type") orelse "%";
    if (argStr(args, "item_type")) |t| {
        if (!std.mem.eql(u8, t, "grammar") and !std.mem.eql(u8, t, "vocab"))
            return .{ .err = "item_type must be grammar or vocab" };
    }
    const item_id = argInt(args, "item_id") orelse -1;
    if (item_id >= 0 and argStr(args, "item_type") == null)
        return .{ .err = "item_id requires item_type" };
    const days = @max(1, @min(argInt(args, "days") orelse 7, 365));
    const max_quality = argInt(args, "max_quality") orelse 5;
    if (max_quality < 0 or max_quality > 5)
        return .{ .err = "max_quality must be between 0 and 5" };
    const limit = clampLimit(argInt(args, "limit"), 50);

    const rows = try ctx.db.query(ctx.arena,
        \\SELECT * FROM (
        \\  SELECT rh.id AS review_id, rh.item_type, rh.item_id, g.pattern AS front, g.reading, g.meaning,
        \\         rh.quality, rh.interval_after, rh.ease_after, rh.reviewed_at
        \\  FROM review_history rh
        \\  JOIN grammar_points g ON g.id = rh.item_id AND rh.item_type = 'grammar'
        \\  UNION ALL
        \\  SELECT rh.id, rh.item_type, rh.item_id, v.word, v.reading, v.meaning,
        \\         rh.quality, rh.interval_after, rh.ease_after, rh.reviewed_at
        \\  FROM review_history rh
        \\  JOIN vocab v ON v.id = rh.item_id AND rh.item_type = 'vocab'
        \\)
        \\WHERE item_type LIKE ?
        \\  AND (? < 0 OR item_id = ?)
        \\  AND reviewed_at::DATE >= CURRENT_DATE - CAST(? AS INTEGER)
        \\  AND quality <= ?
        \\ORDER BY reviewed_at DESC, review_id DESC
        \\LIMIT ?
    , &.{
        .{ .text = type_filter },
        .{ .int = item_id },
        .{ .int = item_id },
        .{ .int = days - 1 },
        .{ .int = max_quality },
        .{ .int = limit },
    });

    var p: Payload = undefined;
    p.init(ctx.arena);
    writeReviewHistory(&p.s, rows) catch return error.OutOfMemory;
    return p.finish();
}

fn writeReviewHistory(s: *Json, rows: db_mod.Rows) !void {
    const cols = review_item_cols ++ [_]Col{
        .{ .name = "quality", .kind = .int },
        .{ .name = "interval_after", .kind = .int },
        .{ .name = "ease_after", .kind = .float },
        .{ .name = "reviewed_at" },
    };
    try s.beginObject();
    try s.objectField("reviews");
    try writeRowsArray(s, rows, &cols);
    try s.endObject();
}

fn getStudySummary(ctx: *Ctx, args: ?std.json.Value) HandlerError!Outcome {
    _ = args;
    const rows = try ctx.db.query(ctx.arena,
        \\SELECT
        \\  (SELECT count(*) FROM grammar_points) AS grammar_total,
        \\  (SELECT count(*) FROM vocab) AS vocab_total,
        \\  (SELECT count(*) FROM learning_status WHERE item_type = 'grammar' AND status = 'learning') AS g_learning,
        \\  (SELECT count(*) FROM learning_status WHERE item_type = 'grammar' AND status = 'review') AS g_review,
        \\  (SELECT count(*) FROM learning_status WHERE item_type = 'grammar' AND status = 'mastered') AS g_mastered,
        \\  (SELECT count(*) FROM learning_status WHERE item_type = 'vocab' AND status = 'learning') AS v_learning,
        \\  (SELECT count(*) FROM learning_status WHERE item_type = 'vocab' AND status = 'review') AS v_review,
        \\  (SELECT count(*) FROM learning_status WHERE item_type = 'vocab' AND status = 'mastered') AS v_mastered,
        \\  (SELECT count(*) FROM learning_status WHERE due_date <= CURRENT_DATE) AS due_today,
        \\  (SELECT count(*) FROM learning_status WHERE due_date = CURRENT_DATE + 1) AS due_tomorrow,
        \\  (SELECT count(*) FROM review_history WHERE reviewed_at::DATE = CURRENT_DATE) AS reviews_today,
        \\  (SELECT count(*) FROM review_history WHERE reviewed_at::DATE >= CURRENT_DATE - 6) AS reviews_last_7_days,
        \\  (SELECT count(DISTINCT reviewed_at::DATE) FROM review_history WHERE reviewed_at::DATE >= CURRENT_DATE - 13) AS active_days_last_14
    , &.{});

    var p: Payload = undefined;
    p.init(ctx.arena);
    writeSummary(&p.s, rows) catch return error.OutOfMemory;
    return p.finish();
}

fn writeSummary(s: *Json, rows: db_mod.Rows) !void {
    const n = struct {
        fn get(r: db_mod.Rows, name: []const u8) i64 {
            return r.getInt(0, name) orelse 0;
        }
    }.get;

    try s.beginObject();
    inline for (.{ .{ "grammar", "grammar_total", "g_" }, .{ "vocab", "vocab_total", "v_" } }) |group| {
        const label, const total_col, const prefix = group;
        const total = n(rows, total_col);
        const learning = n(rows, prefix ++ "learning");
        const review = n(rows, prefix ++ "review");
        const mastered = n(rows, prefix ++ "mastered");
        try s.objectField(label);
        try s.beginObject();
        try s.objectField("total");
        try s.write(total);
        try s.objectField("new");
        try s.write(total - learning - review - mastered);
        try s.objectField("learning");
        try s.write(learning);
        try s.objectField("review");
        try s.write(review);
        try s.objectField("mastered");
        try s.write(mastered);
        try s.endObject();
    }
    inline for (.{ "due_today", "due_tomorrow", "reviews_today", "reviews_last_7_days", "active_days_last_14" }) |field| {
        try s.objectField(field);
        try s.write(n(rows, field));
    }
    try s.endObject();
}

// --- tests --------------------------------------------------------------

const TestEnv = struct {
    db: db_mod.Db,
    arena_state: std.heap.ArenaAllocator,
    ctx: Ctx,

    fn init(env: *TestEnv) !void {
        env.db = try db_mod.Db.open(":memory:");
        errdefer env.db.close();
        try env.db.exec(db_mod.schema_sql);
        try env.db.exec(
            \\INSERT INTO grammar_points (id, pattern, reading, meaning, formation, nuance, register) VALUES
            \\(1, '〜んばかりに', '〜んばかりに', 'as if about to; on the verge of', 'V-ない stem + んばかりに', 'Dramatic description.', 'written'),
            \\(2, '〜をよそに', '〜をよそに', 'ignoring; in defiance of', 'N + をよそに', 'Critical tone.', 'written');
            \\INSERT INTO grammar_examples (id, grammar_id, japanese, reading, english) VALUES
            \\(1, 1, '泣かんばかりに頼んだ。', 'なかんばかりにたのんだ。', 'She begged almost in tears.');
            \\INSERT INTO vocab (id, word, reading, meaning, part_of_speech) VALUES
            \\(1, '顕著', 'けんちょ', 'remarkable; striking', 'na-adjective');
        );
        env.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        env.ctx = .{ .arena = env.arena_state.allocator(), .db = &env.db };
    }

    fn deinit(env: *TestEnv) void {
        env.arena_state.deinit();
        env.db.close();
    }

    fn call(env: *TestEnv, tool_name: []const u8, args_json: []const u8) !std.json.Value {
        const tool = find(tool_name).?;
        const args = try std.json.parseFromSliceLeaky(std.json.Value, env.ctx.arena, args_json, .{});
        const outcome = try tool.handler(&env.ctx, args);
        return switch (outcome) {
            .ok => |payload| try std.json.parseFromSliceLeaky(std.json.Value, env.ctx.arena, payload, .{}),
            .err => |msg| {
                std.debug.print("tool {s} failed: {s}\n", .{ tool_name, msg });
                return error.ToolError;
            },
        };
    }

    fn callExpectError(env: *TestEnv, tool_name: []const u8, args_json: []const u8) ![]const u8 {
        const tool = find(tool_name).?;
        const args = try std.json.parseFromSliceLeaky(std.json.Value, env.ctx.arena, args_json, .{});
        return switch (try tool.handler(&env.ctx, args)) {
            .ok => error.ExpectedToolError,
            .err => |msg| msg,
        };
    }
};

test "tools list JSON is valid and complete" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), list_json, .{});
    try std.testing.expectEqual(registry.len, parsed.object.get("tools").?.array.items.len);
}

test "search and get grammar" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const found = try env.call("search_grammar", "{\"query\":\"ばかり\"}");
    const results = found.object.get("results").?.array;
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("new", results.items[0].object.get("status").?.string);

    const g = try env.call("get_grammar", "{\"id\":1}");
    try std.testing.expectEqualStrings("〜んばかりに", g.object.get("pattern").?.string);
    try std.testing.expect(g.object.get("srs").? == .null);
    try std.testing.expectEqual(@as(usize, 1), g.object.get("examples").?.array.items.len);

    const missing = try env.callExpectError("get_grammar", "{\"id\":999}");
    try std.testing.expect(std.mem.indexOf(u8, missing, "not found") != null);
}

test "record_review advances SM-2 and get_due_reviews sees it" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const first = try env.call("record_review", "{\"item_type\":\"grammar\",\"item_id\":1,\"quality\":5}");
    try std.testing.expectEqual(@as(i64, 1), first.object.get("interval_days").?.integer);
    try std.testing.expectEqualStrings("review", first.object.get("status").?.string);

    const second = try env.call("record_review", "{\"item_type\":\"grammar\",\"item_id\":1,\"quality\":5}");
    try std.testing.expectEqual(@as(i64, 6), second.object.get("interval_days").?.integer);

    const failed = try env.call("record_review", "{\"item_type\":\"grammar\",\"item_id\":1,\"quality\":1}");
    try std.testing.expectEqualStrings("learning", failed.object.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 1), failed.object.get("interval_days").?.integer);

    // interval 1 → due tomorrow, so not in the due list; unreviewed items show as new.
    const due = try env.call("get_due_reviews", "{}");
    try std.testing.expectEqual(@as(usize, 0), due.object.get("due").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), due.object.get("new").?.array.items.len);

    // item_type filter: only the unreviewed vocab word remains.
    const vocab_only = try env.call("get_due_reviews", "{\"item_type\":\"vocab\"}");
    const vocab_new = vocab_only.object.get("new").?.array;
    try std.testing.expectEqual(@as(usize, 1), vocab_new.items.len);
    try std.testing.expectEqualStrings("vocab", vocab_new.items[0].object.get("item_type").?.string);

    const bad = try env.callExpectError("record_review", "{\"item_type\":\"grammar\",\"item_id\":999,\"quality\":5}");
    try std.testing.expect(std.mem.indexOf(u8, bad, "not found") != null);
}

test "add, update, and summary tools" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const added = try env.call("add_grammar", "{\"pattern\":\"〜まみれ\",\"meaning\":\"covered in\"}");
    const new_id = added.object.get("id").?.integer;
    try std.testing.expect(new_id >= 10001);

    var buf: [128]u8 = undefined;
    const upd_args = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"nuance\":\"Negative connotation.\"}}", .{new_id});
    const updated = try env.call("update_grammar", upd_args);
    try std.testing.expect(updated.object.get("updated").?.bool);

    _ = try env.call("add_vocab", "{\"word\":\"拮抗\",\"reading\":\"きっこう\",\"meaning\":\"rivalry; competition\"}");
    _ = try env.call("record_review", "{\"item_type\":\"vocab\",\"item_id\":1,\"quality\":4}");

    const summary = try env.call("get_study_summary", "{}");
    const vocab_stats = summary.object.get("vocab").?.object;
    try std.testing.expectEqual(@as(i64, 2), vocab_stats.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), vocab_stats.get("new").?.integer);
    try std.testing.expectEqual(@as(i64, 1), summary.object.get("reviews_today").?.integer);

    const no_fields = try env.callExpectError("update_vocab", "{\"id\":1}");
    try std.testing.expectEqualStrings("no fields to update", no_fields);

    const listed = try env.call("list_vocab", "{}");
    try std.testing.expectEqual(@as(i64, 2), listed.object.get("total").?.integer);
    const reviewed = try env.call("list_vocab", "{\"status\":\"review\"}");
    try std.testing.expectEqual(@as(i64, 1), reviewed.object.get("total").?.integer);
    try std.testing.expectEqualStrings("顕著", reviewed.object.get("items").?.array.items[0].object.get("word").?.string);
}

test "argument helpers coerce and clamp" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena_state.allocator(),
        \\{"s":"x","i":3,"f_whole":4.0,"f_frac":4.5,"b":true}
    ,
        .{},
    );

    try std.testing.expectEqualStrings("x", argStr(args, "s").?);
    try std.testing.expect(argStr(args, "i") == null); // wrong type
    try std.testing.expect(argStr(args, "missing") == null);
    try std.testing.expect(argStr(null, "s") == null);
    try std.testing.expectEqual(@as(i64, 3), argInt(args, "i").?);
    // Clients often send integers as JSON floats; whole floats coerce.
    try std.testing.expectEqual(@as(i64, 4), argInt(args, "f_whole").?);
    try std.testing.expect(argInt(args, "f_frac") == null);
    try std.testing.expectEqual(true, argBool(args, "b").?);

    try std.testing.expectEqual(@as(i64, 10), clampLimit(null, 10));
    try std.testing.expectEqual(@as(i64, 1), clampLimit(0, 10));
    try std.testing.expectEqual(@as(i64, 1), clampLimit(-5, 10));
    try std.testing.expectEqual(@as(i64, 100), clampLimit(5000, 10));
}

test "handlers reject missing and invalid arguments" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const cases = [_]struct { tool: []const u8, args: []const u8, expect: []const u8 }{
        .{ .tool = "search_grammar", .args = "{}", .expect = "missing required argument: query" },
        .{ .tool = "get_grammar", .args = "{}", .expect = "missing required argument: id" },
        .{ .tool = "add_grammar", .args = "{\"pattern\":\"x\"}", .expect = "missing required argument: meaning" },
        .{ .tool = "add_vocab", .args = "{\"word\":\"x\",\"reading\":\"y\"}", .expect = "missing required argument: meaning" },
        .{ .tool = "list_grammar", .args = "{\"status\":\"bogus\"}", .expect = "invalid status: must be new, learning, review, or mastered" },
        .{ .tool = "list_vocab", .args = "{\"status\":\"bogus\"}", .expect = "invalid status: must be new, learning, review, or mastered" },
        .{ .tool = "get_due_reviews", .args = "{\"item_type\":\"kanji\"}", .expect = "item_type must be grammar or vocab" },
        .{ .tool = "record_review", .args = "{\"item_type\":\"kanji\",\"item_id\":1,\"quality\":4}", .expect = "item_type must be grammar or vocab" },
        .{ .tool = "record_review", .args = "{\"item_type\":\"grammar\",\"item_id\":1,\"quality\":6}", .expect = "quality must be between 0 and 5" },
        .{ .tool = "record_review", .args = "{\"item_type\":\"grammar\",\"item_id\":1,\"quality\":-1}", .expect = "quality must be between 0 and 5" },
        .{ .tool = "update_grammar", .args = "{\"nuance\":\"x\"}", .expect = "missing required argument: id" },
        .{ .tool = "get_review_history", .args = "{\"item_type\":\"kanji\"}", .expect = "item_type must be grammar or vocab" },
        .{ .tool = "get_review_history", .args = "{\"item_id\":1}", .expect = "item_id requires item_type" },
        .{ .tool = "get_review_history", .args = "{\"max_quality\":6}", .expect = "max_quality must be between 0 and 5" },
    };
    for (cases) |case| {
        const msg = try env.callExpectError(case.tool, case.args);
        try std.testing.expectEqualStrings(case.expect, msg);
    }
}

test "list_grammar paginates in id order" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const page = try env.call("list_grammar", "{\"limit\":1,\"offset\":1}");
    try std.testing.expectEqual(@as(i64, 2), page.object.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), page.object.get("offset").?.integer);
    const items = page.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("〜をよそに", items.items[0].object.get("pattern").?.string);

    // Past the end: empty page, same total.
    const beyond = try env.call("list_grammar", "{\"offset\":10}");
    try std.testing.expectEqual(@as(i64, 2), beyond.object.get("total").?.integer);
    try std.testing.expectEqual(@as(usize, 0), beyond.object.get("items").?.array.items.len);
}

test "search_vocab matches word, reading, and meaning" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    for ([_][]const u8{ "顕著", "けんちょ", "striking" }) |term| {
        var buf: [64]u8 = undefined;
        const args = try std.fmt.bufPrint(&buf, "{{\"query\":\"{s}\"}}", .{term});
        const found = try env.call("search_vocab", args);
        const results = found.object.get("results").?.array;
        try std.testing.expectEqual(@as(usize, 1), results.items.len);
        try std.testing.expectEqualStrings("顕著", results.items[0].object.get("word").?.string);
    }

    const nothing = try env.call("search_vocab", "{\"query\":\"zzz-no-match\"}");
    try std.testing.expectEqual(@as(usize, 0), nothing.object.get("results").?.array.items.len);
}

test "add_example verifies the grammar point and appears in get_grammar" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const orphan = try env.callExpectError(
        "add_example",
        "{\"grammar_id\":999,\"japanese\":\"x\",\"english\":\"y\"}",
    );
    try std.testing.expectEqualStrings("grammar point 999 not found", orphan);

    const added = try env.call(
        "add_example",
        "{\"grammar_id\":2,\"japanese\":\"親の心配をよそに、彼は旅に出た。\",\"english\":\"Ignoring his parents' worries, he set off on a journey.\"}",
    );
    try std.testing.expect(added.object.get("id").?.integer >= 10001);

    const g = try env.call("get_grammar", "{\"id\":2}");
    const examples = g.object.get("examples").?.array;
    try std.testing.expectEqual(@as(usize, 1), examples.items.len);
    // The optional reading was omitted and must come back as null, not "".
    try std.testing.expect(examples.items[0].object.get("reading").? == .null);
}

test "updates change only the provided whitelisted fields" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const updated = try env.call("update_vocab", "{\"id\":1,\"meaning\":\"notable; prominent\"}");
    try std.testing.expect(updated.object.get("updated").?.bool);

    const found = try env.call("search_vocab", "{\"query\":\"prominent\"}");
    const row = found.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("顕著", row.get("word").?.string); // untouched
    try std.testing.expectEqualStrings("notable; prominent", row.get("meaning").?.string);

    const missing = try env.callExpectError("update_vocab", "{\"id\":999,\"meaning\":\"x\"}");
    try std.testing.expectEqualStrings("vocab id 999 not found", missing);
}

test "get_review_history returns past quiz results, newest first" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Nothing reviewed yet: empty history, not an error.
    const before = try env.call("get_review_history", "{}");
    try std.testing.expectEqual(@as(usize, 0), before.object.get("reviews").?.array.items.len);

    _ = try env.call("record_review", "{\"item_type\":\"grammar\",\"item_id\":1,\"quality\":5}");
    _ = try env.call("record_review", "{\"item_type\":\"vocab\",\"item_id\":1,\"quality\":2}");

    const all = try env.call("get_review_history", "{}");
    const reviews = all.object.get("reviews").?.array;
    try std.testing.expectEqual(@as(usize, 2), reviews.items.len);
    // The vocab review came last, so it is first.
    const latest = reviews.items[0].object;
    try std.testing.expectEqualStrings("vocab", latest.get("item_type").?.string);
    try std.testing.expectEqualStrings("顕著", latest.get("front").?.string);
    try std.testing.expectEqual(@as(i64, 2), latest.get("quality").?.integer);
    try std.testing.expect(latest.get("reviewed_at").?.string.len > 0);

    // Failed recalls only.
    const failures = try env.call("get_review_history", "{\"max_quality\":2}");
    const failed = failures.object.get("reviews").?.array;
    try std.testing.expectEqual(@as(usize, 1), failed.items.len);
    try std.testing.expectEqualStrings("vocab", failed.items[0].object.get("item_type").?.string);

    // Per-type and per-item filters.
    const grammar_only = try env.call("get_review_history", "{\"item_type\":\"grammar\"}");
    const g_reviews = grammar_only.object.get("reviews").?.array;
    try std.testing.expectEqual(@as(usize, 1), g_reviews.items.len);
    try std.testing.expectEqualStrings("〜んばかりに", g_reviews.items[0].object.get("front").?.string);

    _ = try env.call("record_review", "{\"item_type\":\"vocab\",\"item_id\":1,\"quality\":4}");
    const one_item = try env.call("get_review_history", "{\"item_type\":\"vocab\",\"item_id\":1}");
    try std.testing.expectEqual(@as(usize, 2), one_item.object.get("reviews").?.array.items.len);
}

test "get_due_reviews respects include_new and new_limit" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const quiet = try env.call("get_due_reviews", "{\"include_new\":false}");
    try std.testing.expectEqual(@as(usize, 0), quiet.object.get("due").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), quiet.object.get("new").?.array.items.len);

    const capped = try env.call("get_due_reviews", "{\"new_limit\":1}");
    try std.testing.expectEqual(@as(usize, 1), capped.object.get("new").?.array.items.len);
}
