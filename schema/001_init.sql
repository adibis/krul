-- Krul schema v1
-- Run: psql krul -f schema/001_init.sql

CREATE EXTENSION IF NOT EXISTS vector;

-- ── Projects ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS krul_projects (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    root_path  TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Entities (plugin-extracted) ──────────────────────────────────────────────
-- kind is plain TEXT, not a DB-level enum: the actual vocabulary is defined
-- by whichever ontology file the project's krul.toml points at (see
-- ontologies/dv-uvm.json for the shipped example — MODULE, PORT, COVERGROUP,
-- UVM_AGENT, … — or ontologies/stock-ta.json for an unrelated one).
CREATE TABLE IF NOT EXISTS entities (
    id          BIGSERIAL PRIMARY KEY,
    project_id  INT  NOT NULL REFERENCES krul_projects(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL,
    name        TEXT NOT NULL,
    file_path   TEXT NOT NULL,
    line_start  INT  NOT NULL,
    line_end    INT  NOT NULL,
    confidence  FLOAT NOT NULL DEFAULT 1.0,
    indexed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    embedding   vector(768)      -- pooled embedding from whichever model the indexer plugin uses (768 dims to match the shipped codebert plugin's GraphCodeBERT output)
);

CREATE INDEX IF NOT EXISTS idx_entities_kind       ON entities(kind);
CREATE INDEX IF NOT EXISTS idx_entities_name       ON entities(name text_pattern_ops);
CREATE INDEX IF NOT EXISTS idx_entities_project    ON entities(project_id);
CREATE INDEX IF NOT EXISTS idx_entities_file       ON entities(file_path);

-- Approximate nearest-neighbour index (pgvector HNSW)
CREATE INDEX IF NOT EXISTS idx_entities_embedding
    ON entities USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- ── Relationships ─────────────────────────────────────────────────────────────
-- kind is plain TEXT for the same reason as entities.kind above — the
-- ontology's relation_kind list is the actual vocabulary, not this schema.
CREATE TABLE IF NOT EXISTS relationships (
    id         BIGSERIAL PRIMARY KEY,
    from_id    BIGINT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    to_id      BIGINT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL,
    properties JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_rel_from ON relationships(from_id);
CREATE INDEX IF NOT EXISTS idx_rel_to   ON relationships(to_id);
CREATE INDEX IF NOT EXISTS idx_rel_kind ON relationships(kind);

-- ── Task Queue ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tasks (
    id           BIGSERIAL PRIMARY KEY,
    kind         TEXT NOT NULL,   -- e.g. shell, index, triage, coverage_gaps (gear-defined, not fixed by krul)
    state        TEXT NOT NULL DEFAULT 'pending',  -- pending, running, done, failed
    params       JSONB NOT NULL DEFAULT '{}'::jsonb,
    stdout_tail  TEXT,
    exit_code    INT,
    result       JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at   TIMESTAMPTZ,
    completed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_tasks_state   ON tasks(state);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at DESC);

-- ── Findings (structured LLM output written back to graph) ───────────────────
CREATE TABLE IF NOT EXISTS findings (
    id          BIGSERIAL PRIMARY KEY,
    kind        TEXT NOT NULL,  -- e.g. assert_triage, coverage_gap, bug_hypothesis (gear-defined, not fixed by krul)
    task_id     BIGINT REFERENCES tasks(id) ON DELETE SET NULL,
    entity_id   BIGINT REFERENCES entities(id) ON DELETE SET NULL,
    data        JSONB NOT NULL,
    confidence  FLOAT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_findings_kind   ON findings(kind);
CREATE INDEX IF NOT EXISTS idx_findings_entity ON findings(entity_id);
