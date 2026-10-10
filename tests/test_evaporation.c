/* test_evaporation.c — DB smoke test for Phase 10 (evaporation-based
 * invalidation). Exercises krl_evaporation_migrate, krl_reinforce_entity/
 * _relation, and krl_entity_strength/_relation against a real Postgres
 * connection — the decay math and the strength_min floor are read-time SQL,
 * not something a pure-Zig/C unit test without a database could cover.
 *
 * Requires a disposable Postgres database. Create it once with:
 *   createdb krul_test
 * Connection string comes from KRUL_TEST_DB, default "dbname=krul_test host=localhost".
 * Safe to re-run: deletes its own test project's rows at the start of each run.
 *
 * Not covered here: concurrent reinforcement. Reinforcement is a blind
 * UPDATE ... SET strength = 1.0 (not a read-modify-write), so unlike an
 * increment-based counter it structurally cannot lose a concurrent update —
 * there is no stale-read-then-write window to race. A concurrency stress
 * test would be exercising Postgres's own row-update atomicity, not
 * anything particular to this code.
 */
#include "../src/c/db.h"
#include <libpq-fe.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static int failures = 0;

#define CHECK(cond, msg) do { \
    if (cond) { printf("PASS: %s\n", msg); } \
    else { fprintf(stderr, "FAIL: %s\n", msg); failures++; } \
} while (0)

#define CHECK_NEAR(a, b, eps, msg) do { \
    double _a = (a), _b = (b); \
    if (fabs(_a - _b) <= (eps)) { printf("PASS: %s (%f)\n", msg, _a); } \
    else { fprintf(stderr, "FAIL: %s (got %f, want %f +/- %f)\n", msg, _a, _b, (double)(eps)); failures++; } \
} while (0)

/* Backdates last_reinforced_at directly via a second raw connection — test-only,
 * entity_id/relation_id here always come from our own inserts above, never
 * from external input, so plain snprintf interpolation is fine. */
static void backdate(PGconn *raw, const char *table, int64_t id, double hours_ago) {
    char sql[256];
    snprintf(sql, sizeof(sql),
        "UPDATE %s SET last_reinforced_at = NOW() - INTERVAL '%f hours' WHERE id = %lld",
        table, hours_ago, (long long)id);
    PGresult *r = PQexec(raw, sql);
    PQclear(r);
}

int main(void) {
    const char *conninfo = getenv("KRUL_TEST_DB");
    if (!conninfo) conninfo = "dbname=krul_test host=localhost";

    KrlDb *db = krl_db_open(conninfo);
    if (!db) { fprintf(stderr, "FAIL: could not open %s\n", conninfo); return 1; }

    PGconn *raw = PQconnectdb(conninfo);
    if (PQstatus(raw) != CONNECTION_OK) {
        fprintf(stderr, "FAIL: raw connection: %s\n", PQerrorMessage(raw));
        return 1;
    }

    CHECK(krl_db_migrate(db) == 0, "base schema migrate");
    CHECK(krl_evaporation_migrate(db) == 0, "evaporation migrate adds columns");
    CHECK(krl_evaporation_migrate(db) == 0, "evaporation migrate is idempotent on rerun");

    int64_t project_id = krl_project_get_or_create(db, "evap_test_project", "/tmp/evap_test");
    CHECK(project_id > 0, "create test project");

    /* Reset to a clean slate; cascades to relationships via entities FK. */
    {
        char sql[128];
        snprintf(sql, sizeof(sql), "DELETE FROM entities WHERE project_id = %lld",
                 (long long)project_id);
        PGresult *r = PQexec(raw, sql);
        PQclear(r);
    }

    const double HALF_LIFE_HOURS = 24.0;
    const double STRENGTH_MIN    = 0.05;

    /* ── Entity: fresh strength, decay, floor, reinforcement ──────────────── */

    int64_t eid = 0;
    int rc = krl_entity_insert(db, project_id, "MODULE", "evap_entity",
                                "evap_test.sv", 1, 10, 1.0f, &eid);
    CHECK(rc == 0 && eid > 0, "insert test entity");

    double s = -1.0;
    rc = krl_entity_strength(db, eid, HALF_LIFE_HOURS, STRENGTH_MIN, &s);
    CHECK(rc == 0, "read strength of fresh entity");
    CHECK_NEAR(s, 1.0, 0.001, "fresh entity strength reads as the ceiling, 1.0");

    backdate(raw, "entities", eid, HALF_LIFE_HOURS /* exactly one half-life */);
    rc = krl_entity_strength(db, eid, HALF_LIFE_HOURS, STRENGTH_MIN, &s);
    CHECK(rc == 0, "read strength after one half-life");
    CHECK_NEAR(s, 0.5, 0.01, "one half-life elapsed halves strength");

    backdate(raw, "entities", eid, HALF_LIFE_HOURS * 100 /* far past any realistic half-life */);
    rc = krl_entity_strength(db, eid, HALF_LIFE_HOURS, STRENGTH_MIN, &s);
    CHECK(rc == 0, "read strength after 100 half-lives");
    CHECK_NEAR(s, STRENGTH_MIN, 1e-9, "strength clamps exactly at strength_min, never below");
    CHECK(s > 0.0, "clamped strength is strictly positive, never exactly zero");

    rc = krl_reinforce_entity(db, eid);
    CHECK(rc == 0, "reinforce long-decayed entity");
    rc = krl_entity_strength(db, eid, HALF_LIFE_HOURS, STRENGTH_MIN, &s);
    CHECK(rc == 0, "read strength immediately after reinforcement");
    CHECK_NEAR(s, 1.0, 0.001, "reinforcement resets strength back to the ceiling");

    rc = krl_reinforce_entity(db, /*nonexistent id*/ 999999999);
    CHECK(rc == -1, "reinforcing a nonexistent entity id is reported as an error");

    /* ── Relationship: same mechanism, resolved through the entity graph ──── */

    int64_t eid2 = 0;
    rc = krl_entity_insert(db, project_id, "MODULE", "evap_entity_2",
                            "evap_test.sv", 20, 30, 1.0f, &eid2);
    CHECK(rc == 0 && eid2 > 0, "insert second test entity for relation endpoint");

    rc = krl_relation_insert(db, project_id, "DRIVES",
                              "MODULE", "evap_entity", "MODULE", "evap_entity_2", 1.0f);
    CHECK(rc == 0, "insert test relation");

    int64_t rid = 0;
    {
        char sql[192];
        snprintf(sql, sizeof(sql),
            "SELECT id FROM relationships WHERE project_id = %lld AND kind = 'DRIVES'"
            " AND from_entity_id = %lld AND to_entity_id = %lld",
            (long long)project_id, (long long)eid, (long long)eid2);
        PGresult *r = PQexec(raw, sql);
        if (PQresultStatus(r) == PGRES_TUPLES_OK && PQntuples(r) > 0)
            rid = atoll(PQgetvalue(r, 0, 0));
        PQclear(r);
    }
    CHECK(rid > 0, "resolve inserted relation's id");

    double rs = -1.0;
    rc = krl_relation_strength(db, rid, HALF_LIFE_HOURS, STRENGTH_MIN, &rs);
    CHECK(rc == 0, "read strength of fresh relation");
    CHECK_NEAR(rs, 1.0, 0.001, "fresh relation strength reads as the ceiling, 1.0");

    backdate(raw, "relationships", rid, HALF_LIFE_HOURS * 100);
    rc = krl_relation_strength(db, rid, HALF_LIFE_HOURS, STRENGTH_MIN, &rs);
    CHECK(rc == 0, "read strength of relation after 100 half-lives");
    CHECK_NEAR(rs, STRENGTH_MIN, 1e-9, "relation strength also clamps at strength_min");

    rc = krl_reinforce_relation(db, rid);
    CHECK(rc == 0, "reinforce long-decayed relation");
    rc = krl_relation_strength(db, rid, HALF_LIFE_HOURS, STRENGTH_MIN, &rs);
    CHECK(rc == 0, "read relation strength immediately after reinforcement");
    CHECK_NEAR(rs, 1.0, 0.001, "reinforcement resets relation strength to the ceiling");

    /* ── Visibility filtering: krl_gothos_query_entities/relations exclude
     * decayed rows below visibility_threshold; krl_entity_get_by_id never
     * filters, so an excluded row is still directly reachable by id ──── */

    const double VISIBILITY_THRESHOLD = 0.1; /* above STRENGTH_MIN (0.05) on purpose */

    /* eid was reinforced above; decay it again so this section doesn't
     * depend on state left over from the earlier checks. */
    backdate(raw, "entities", eid, HALF_LIFE_HOURS * 100);

    char qbuf[65536];
    rc = krl_gothos_query_entities(db, project_id, "MODULE", NULL,
                                    HALF_LIFE_HOURS, STRENGTH_MIN, VISIBILITY_THRESHOLD,
                                    qbuf, sizeof(qbuf));
    CHECK(rc == 0, "query_entities succeeds while a row is below visibility_threshold");
    CHECK(strstr(qbuf, "\"evap_entity\"") == NULL,
          "decayed-below-threshold entity is excluded from default query_entities results");
    CHECK(strstr(qbuf, "evap_entity_2") != NULL,
          "a still-fresh sibling entity remains in default query_entities results");

    char idbuf[4096];
    rc = krl_entity_get_by_id(db, eid, idbuf, sizeof(idbuf));
    CHECK(rc == 0 && strstr(idbuf, "evap_entity") != NULL,
          "excluded entity is still directly fetchable by id");

    rc = krl_entity_get_by_id(db, 999999999, idbuf, sizeof(idbuf));
    CHECK(rc == -1, "fetching a nonexistent id by id is reported as an error");

    rc = krl_reinforce_entity(db, eid);
    CHECK(rc == 0, "reinforce the decayed entity before re-querying");
    rc = krl_gothos_query_entities(db, project_id, "MODULE", NULL,
                                    HALF_LIFE_HOURS, STRENGTH_MIN, VISIBILITY_THRESHOLD,
                                    qbuf, sizeof(qbuf));
    CHECK(rc == 0 && strstr(qbuf, "\"evap_entity\"") != NULL,
          "reinforcing the excluded entity brings it back into default query_entities results");

    backdate(raw, "relationships", rid, HALF_LIFE_HOURS * 100);
    rc = krl_gothos_query_relations(db, project_id, NULL, "DRIVES",
                                     HALF_LIFE_HOURS, STRENGTH_MIN, VISIBILITY_THRESHOLD,
                                     qbuf, sizeof(qbuf));
    CHECK(rc == 0, "query_relations succeeds while a row is below visibility_threshold");
    CHECK(strstr(qbuf, "DRIVES") == NULL,
          "decayed-below-threshold relation is excluded from default query_relations results");

    /* ── get_context: relation-strength and entity-strength are filtered
     * independently; the focus entity is always included regardless ────── */

    char ctxbuf[65536];
    rc = krl_gothos_get_context(db, project_id, "evap_entity", 1,
                                 HALF_LIFE_HOURS, STRENGTH_MIN, VISIBILITY_THRESHOLD,
                                 ctxbuf, sizeof(ctxbuf));
    CHECK(rc == 0, "get_context succeeds with a decayed connecting relation");
    CHECK(strstr(ctxbuf, "DRIVES") == NULL,
          "get_context's relations list excludes the still-decayed DRIVES relation");
    CHECK(strstr(ctxbuf, "\"evap_entity_2\"") != NULL,
          "get_context's entities list still includes a neighbor whose own strength is fresh");

    backdate(raw, "entities", eid2, HALF_LIFE_HOURS * 100);
    rc = krl_gothos_get_context(db, project_id, "evap_entity", 1,
                                 HALF_LIFE_HOURS, STRENGTH_MIN, VISIBILITY_THRESHOLD,
                                 ctxbuf, sizeof(ctxbuf));
    CHECK(rc == 0, "get_context succeeds with a decayed neighbor entity");
    CHECK(strstr(ctxbuf, "\"evap_entity_2\"") == NULL,
          "get_context's entities list excludes a neighbor decayed below visibility_threshold");

    backdate(raw, "entities", eid, HALF_LIFE_HOURS * 100);
    rc = krl_gothos_get_context(db, project_id, "evap_entity", 1,
                                 HALF_LIFE_HOURS, STRENGTH_MIN, VISIBILITY_THRESHOLD,
                                 ctxbuf, sizeof(ctxbuf));
    CHECK(rc == 0, "get_context succeeds with the focus entity itself decayed");
    CHECK(strstr(ctxbuf, "\"evap_entity\"") != NULL,
          "get_context always includes the focus entity, even decayed below visibility_threshold");

    /* ── no_covergroup: same exclude/reinforce/reappear cycle ────────────── */

    int64_t agent_id = 0;
    rc = krl_entity_insert(db, project_id, "UVM_AGENT", "evap_agent",
                            "evap_test.sv", 40, 50, 1.0f, &agent_id);
    CHECK(rc == 0 && agent_id > 0, "insert test UVM_AGENT with no coverage relation");

    rc = krl_gothos_no_covergroup(db, project_id,
                                   HALF_LIFE_HOURS, STRENGTH_MIN, VISIBILITY_THRESHOLD,
                                   qbuf, sizeof(qbuf));
    CHECK(rc == 0 && strstr(qbuf, "evap_agent") != NULL,
          "fresh UVM_AGENT with no coverage appears in no_covergroup results");

    backdate(raw, "entities", agent_id, HALF_LIFE_HOURS * 100);
    rc = krl_gothos_no_covergroup(db, project_id,
                                   HALF_LIFE_HOURS, STRENGTH_MIN, VISIBILITY_THRESHOLD,
                                   qbuf, sizeof(qbuf));
    CHECK(rc == 0 && strstr(qbuf, "evap_agent") == NULL,
          "decayed-below-threshold UVM_AGENT is excluded from no_covergroup results");

    rc = krl_reinforce_entity(db, agent_id);
    CHECK(rc == 0, "reinforce the decayed UVM_AGENT");
    rc = krl_gothos_no_covergroup(db, project_id,
                                   HALF_LIFE_HOURS, STRENGTH_MIN, VISIBILITY_THRESHOLD,
                                   qbuf, sizeof(qbuf));
    CHECK(rc == 0 && strstr(qbuf, "evap_agent") != NULL,
          "reinforcing the excluded UVM_AGENT brings it back into no_covergroup results");

    PQfinish(raw);
    krl_db_close(db);

    if (failures > 0) {
        fprintf(stderr, "\n%d check(s) FAILED\n", failures);
        return 1;
    }
    printf("\nAll checks passed.\n");
    return 0;
}
