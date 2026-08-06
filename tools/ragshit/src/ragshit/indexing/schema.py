"""SQLite schema for the Ragshit index.

Schema overview (see docs/schema.md):

* repositories      — stable repo identifiers
* files             — one row per indexed file, keyed (repo_id, path)
* chunks            — one row per source-addressable chunk
* git_refs          — branch/HEAD recorded at last index run
* index_runs        — explicit run metadata (allowed to change each run)
* chunks_fts        — FTS5 external-content table over chunks (when FTS5
                      is available)

Chunk identifiers are stable SHA-256 digests of source properties, never
random UUIDs and never absolute paths.
"""

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS repositories (
    id         TEXT PRIMARY KEY,
    root_path  TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS files (
    id           INTEGER PRIMARY KEY,
    repo_id      TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
    path         TEXT NOT NULL,
    kind         TEXT NOT NULL,
    language     TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    byte_size    INTEGER NOT NULL,
    line_count   INTEGER NOT NULL,
    tracked      INTEGER NOT NULL,
    last_commit  TEXT,
    indexed_at   TEXT NOT NULL,
    UNIQUE (repo_id, path)
);
CREATE INDEX IF NOT EXISTS idx_files_repo ON files(repo_id);

CREATE TABLE IF NOT EXISTS chunks (
    id              INTEGER PRIMARY KEY,
    chunk_id        TEXT NOT NULL UNIQUE,
    file_id         INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    repo_id         TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
    path            TEXT NOT NULL,
    start_line      INTEGER NOT NULL,
    end_line        INTEGER NOT NULL,
    content         TEXT NOT NULL,
    content_hash    TEXT NOT NULL,
    kind            TEXT NOT NULL,
    structural_name TEXT,
    heading         TEXT,
    language        TEXT NOT NULL,
    commit_hash     TEXT,
    confidence      REAL NOT NULL DEFAULT 0.0,
    index_run_id    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chunks_repo_path ON chunks(repo_id, path);
CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_id);
CREATE INDEX IF NOT EXISTS idx_chunks_start ON chunks(path, start_line);

CREATE TABLE IF NOT EXISTS git_refs (
    repo_id    TEXT PRIMARY KEY REFERENCES repositories(id) ON DELETE CASCADE,
    branch     TEXT,
    head       TEXT,
    is_detached INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS index_runs (
    id              INTEGER PRIMARY KEY,
    repo_id         TEXT NOT NULL,
    started_at      TEXT NOT NULL,
    finished_at     TEXT NOT NULL,
    status          TEXT NOT NULL,
    files_scanned   INTEGER NOT NULL DEFAULT 0,
    files_added     INTEGER NOT NULL DEFAULT 0,
    files_updated   INTEGER NOT NULL DEFAULT 0,
    files_unchanged INTEGER NOT NULL DEFAULT 0,
    files_removed   INTEGER NOT NULL DEFAULT 0,
    files_skipped   INTEGER NOT NULL DEFAULT 0,
    chunks_added    INTEGER NOT NULL DEFAULT 0,
    elapsed_ms      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_runs_repo ON index_runs(repo_id);
"""

FTS5_SQL = """
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    content,
    structural_name,
    path,
    content='chunks',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
    INSERT INTO chunks_fts(rowid, content, structural_name, path)
    VALUES (new.id, new.content, coalesce(new.structural_name, ''), new.path);
END;

CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, content, structural_name, path)
    VALUES ('delete', old.id, old.content, coalesce(old.structural_name, ''), old.path);
END;

CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, content, structural_name, path)
    VALUES ('delete', old.id, old.content, coalesce(old.structural_name, ''), old.path);
    INSERT INTO chunks_fts(rowid, content, structural_name, path)
    VALUES (new.id, new.content, coalesce(new.structural_name, ''), new.path);
END;
"""
