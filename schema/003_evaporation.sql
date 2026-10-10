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
