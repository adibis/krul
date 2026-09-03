-- Kanban task board for krul
-- Applied by krl_kanban_migrate() at daemon startup (idempotent).

CREATE TABLE IF NOT EXISTS kanban_tasks (
  id           TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  title        TEXT NOT NULL,
  body         TEXT,
  status       TEXT NOT NULL DEFAULT 'triage'
    CONSTRAINT kanban_status CHECK (status IN (
      'triage','todo','ready','running','blocked','review','done','archived')),
  priority     INTEGER NOT NULL DEFAULT 50,
  created_by   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at   TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  gear_name    TEXT,        -- which gear created or owns this task
  gear_run_id  BIGINT,      -- FK to tasks.id (daemon task queue entry)
  linked_finding_id BIGINT  -- FK to a gothos finding entity id
);

CREATE TABLE IF NOT EXISTS kanban_task_links (
  parent_id TEXT NOT NULL REFERENCES kanban_tasks(id) ON DELETE CASCADE,
  child_id  TEXT NOT NULL REFERENCES kanban_tasks(id) ON DELETE CASCADE,
  PRIMARY KEY (parent_id, child_id)
);

CREATE TABLE IF NOT EXISTS kanban_events (
  id         BIGSERIAL PRIMARY KEY,
  task_id    TEXT NOT NULL REFERENCES kanban_tasks(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL,
  payload    JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_kanban_status ON kanban_tasks(status);
CREATE INDEX IF NOT EXISTS idx_kanban_gear   ON kanban_tasks(gear_name);
CREATE INDEX IF NOT EXISTS idx_kanban_events ON kanban_events(task_id, created_at DESC);
