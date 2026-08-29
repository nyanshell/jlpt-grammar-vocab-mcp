-- Idempotent schema, executed on every startup.
-- Sequences start at 10001; seed data uses explicit ids 1..N so they never collide.

CREATE SEQUENCE IF NOT EXISTS seq_grammar START 10001;
CREATE SEQUENCE IF NOT EXISTS seq_example START 10001;
CREATE SEQUENCE IF NOT EXISTS seq_vocab START 10001;
CREATE SEQUENCE IF NOT EXISTS seq_review START 1;

CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS grammar_points (
    id INTEGER PRIMARY KEY DEFAULT nextval('seq_grammar'),
    level TEXT NOT NULL DEFAULT 'N1',
    pattern TEXT NOT NULL,
    reading TEXT,
    meaning TEXT NOT NULL,
    formation TEXT,
    nuance TEXT,
    register TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS grammar_examples (
    id INTEGER PRIMARY KEY DEFAULT nextval('seq_example'),
    grammar_id INTEGER NOT NULL REFERENCES grammar_points (id),
    japanese TEXT NOT NULL,
    reading TEXT,
    english TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS vocab (
    id INTEGER PRIMARY KEY DEFAULT nextval('seq_vocab'),
    level TEXT NOT NULL DEFAULT 'N1',
    word TEXT NOT NULL,
    reading TEXT NOT NULL,
    meaning TEXT NOT NULL,
    part_of_speech TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS learning_status (
    item_type TEXT NOT NULL,
    item_id INTEGER NOT NULL,
    ease_factor DOUBLE NOT NULL DEFAULT 2.5,
    interval_days INTEGER NOT NULL DEFAULT 0,
    repetitions INTEGER NOT NULL DEFAULT 0,
    due_date DATE NOT NULL DEFAULT CURRENT_DATE,
    status TEXT NOT NULL DEFAULT 'learning',
    last_reviewed_at TIMESTAMP,
    PRIMARY KEY (item_type, item_id)
);

CREATE TABLE IF NOT EXISTS review_history (
    id INTEGER PRIMARY KEY DEFAULT nextval('seq_review'),
    item_type TEXT NOT NULL,
    item_id INTEGER NOT NULL,
    quality INTEGER NOT NULL,
    interval_after INTEGER NOT NULL,
    ease_after DOUBLE NOT NULL,
    reviewed_at TIMESTAMP NOT NULL DEFAULT now()
);

INSERT OR REPLACE INTO meta VALUES ('schema_version', '1');
