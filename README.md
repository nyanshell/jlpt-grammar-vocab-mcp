# jlpt-grammar-mcp

A remote [MCP](https://modelcontextprotocol.io/) server for JLPT **N1** study, written in
[Zig](https://ziglang.org/) with [DuckDB](https://duckdb.org/) storage. Connect it to
Claude as a [custom connector](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp)
and Claude can look up N1 grammar and vocabulary, quiz you, and track your progress
with SM-2 spaced repetition — all persisted in a single-user DuckDB file.

Ships seeded with 92 canonical N1 grammar points (formation, nuance, register, and
example sentences with kana readings) and 50 N1 vocabulary entries. Claude can grow
the database over time through the `add_*` / `update_*` tools.

## Tools

| Tool | Purpose |
|---|---|
| `search_grammar` / `get_grammar` / `list_grammar` | Find and read grammar points (with examples and SRS state) |
| `search_vocab` | Find vocabulary |
| `add_grammar` / `update_grammar` / `add_example` | Grow and refine grammar content |
| `add_vocab` / `update_vocab` | Grow vocabulary content |
| `get_due_reviews` | Items due for review today, plus a few never-studied items |
| `record_review` | Record a review result (quality 0–5) and reschedule with SM-2 |
| `get_study_summary` | Progress counts, reviews today / this week, due counts |

## Protocol

Stateless MCP over the Streamable HTTP transport: `POST /mcp/<MCP_SECRET>` with
JSON-RPC 2.0 (`initialize`, `ping`, `tools/list`, `tools/call`; notifications get
`202 Accepted`). Responses are plain `application/json`; there are no SSE streams
and no sessions. `GET /healthz` is the health check. Anything else — including a
wrong secret — is a `404`.

Authentication is the secret URL path: no OAuth. Origin checks are deliberately
omitted; the secret path is the access control, and TLS is expected to be
terminated by the reverse proxy or hosting platform in front of the server.

## Configuration

| Env var | Default | |
|---|---|---|
| `MCP_SECRET` | — | **Required**, ≥ 16 chars. Path segment of the MCP endpoint. |
| `PORT` | `8080` | Listen port. |
| `BIND_ADDR` | `0.0.0.0` | Listen address. |
| `DB_PATH` | `./data/jlpt.duckdb` | DuckDB database file (parent dir is created). |

Generate a secret with e.g. `openssl rand -hex 24`.

## Build and run locally

Requires Zig `0.16.0-dev.2682+02142a54d` (pinned; see notes below). The pinned
`libduckdb` v1.4.1 release zip is fetched automatically by the Zig package manager.

```sh
zig build                       # or -Doptimize=ReleaseSafe
zig build test
MCP_SECRET=$(openssl rand -hex 24) ./zig-out/bin/jlpt-mcp-server
```

If you have DuckDB installed system-wide, `-Dduckdb-lib-dir=/path/to/lib` overrides
the bundled dependency.

Smoke test:

```sh
curl localhost:8080/healthz
curl -X POST localhost:8080/mcp/$MCP_SECRET -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Docker

```sh
docker build -t jlpt-mcp-server .
docker run -d -p 8080:8080 \
  -e MCP_SECRET=your-long-random-secret \
  -v jlpt-data:/data \
  jlpt-mcp-server
```

The image is multi-stage (Zig toolchain + build → slim Debian runtime with
`libduckdb.so`), runs as a non-root user, and stores the database in the `/data`
volume. Zig dev-build tarballs are eventually pruned from `ziglang.org/builds`;
the Dockerfile defaults to a community mirror and accepts
`--build-arg ZIG_URL=...` if that mirror ever drops the version.

## Connecting Claude

1. Deploy the container behind HTTPS (a reverse proxy, Fly.io, Cloud Run, etc. —
   Claude requires TLS).
2. In Claude: **Settings → Connectors → Add custom connector**, with URL
   `https://your-host/mcp/<MCP_SECRET>`. No OAuth configuration is needed.
3. Ask Claude to quiz you: it will call `get_due_reviews`, present items, and
   `record_review` your answers.

## Database schema

DuckDB file with idempotent DDL applied at startup (`src/schema.sql`); the seed
(`src/seed.sql`) loads in one transaction only when `grammar_points` is empty.
Seed rows use explicit ids 1..N while sequences start at 10001, so tool-inserted
rows never collide.

- `grammar_points` — pattern, reading, meaning, formation, nuance, register, level
- `grammar_examples` — Japanese / kana reading / English, FK to grammar
- `vocab` — word, reading, meaning, part of speech, level
- `learning_status` — per `(item_type, item_id)`: SM-2 ease factor, interval,
  repetitions, due date, derived status (`learning` / `review` / `mastered`)
- `review_history` — every review with quality and post-review state

Single user by design: no users table, no sessions.

## Engineering notes

- **Zig version pinning.** The code targets the post-“Writergate” `std.Io` API
  (0.16-dev): `main(init: std.process.Init)`, `std.Io.net`, `std.json.Stringify`,
  buffer-fed readers/writers. CI (`mlugg/setup-zig`) and the Dockerfile pin the
  exact same version. Upgrading Zig will require mechanical API updates — and
  `@cImport` (used in `src/db.zig`) is slated for replacement by the
  `addTranslateC` build step in a future Zig release.
- **DuckDB API level.** `src/db.zig` uses the materialized value API
  (`duckdb_value_varchar` etc.), deprecated upstream but shipped in v1.4.x.
  Result sets here are tiny; a future move to `duckdb_fetch_chunk` is contained
  in that one file.
- **Memory.** One arena per HTTP request; DuckDB C strings are duped into the
  arena and freed immediately. SM-2 math is pure Zig (`src/srs.zig`); all
  date/time arithmetic happens in SQL (`CURRENT_DATE + interval`), so the Zig
  code never touches a clock.
