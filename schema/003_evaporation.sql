-- Krul schema v3 — Phase 10: evaporation-based invalidation
-- Run: psql krul -f schema/003_evaporation.sql
-- Applied at daemon startup by krl_evaporation_migrate() (idempotent).

-- Pheromone-style strength: reinforcement resets to 1.0 (not an increment),
-- decay is computed at read time from last_reinforced_at, never swept by a
-- batch job. See PLAN.md Phase 10 for the full design, including the
-- strength_min floor (MAX-MIN Ant System bound) applied at read time.
ALTER TABLE entities
    ADD COLUMN IF NOT EXISTS strength FLOAT NOT NULL DEFAULT 1.0,
    ADD COLUMN IF NOT EXISTS last_reinforced_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

ALTER TABLE relationships
    ADD COLUMN IF NOT EXISTS strength FLOAT NOT NULL DEFAULT 1.0,
    ADD COLUMN IF NOT EXISTS last_reinforced_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Every reinforcement is logged with whatever candidate set the caller was
-- choosing from (NULL if none was supplied). Required for propensity
-- correction later: without the candidate set, reinforcement data is
-- confounded with retrieval bias (an edge looks weak because it was rarely
-- surfaced, not because it was actually worse), and that confound can't be
-- untangled retroactively once the data is gone — so this logs from day
-- one of reinforcement existing, not as a later addition.
CREATE TABLE IF NOT EXISTS reinforcement_events (
    id            BIGSERIAL PRIMARY KEY,
    target_kind   TEXT NOT NULL CHECK (target_kind IN ('entity', 'relation')),
    target_id     BIGINT NOT NULL,
    candidate_set JSONB,
    reinforced_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reinforcement_events_target
    ON reinforcement_events(target_kind, target_id);
