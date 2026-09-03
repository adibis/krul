#include "db.h"
#include <libpq-fe.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

struct KrlDb {
    PGconn *conn;
};

KrlDb *krl_db_open(const char *conninfo) {
    KrlDb *db = calloc(1, sizeof(KrlDb));
    if (!db) return NULL;

    db->conn = PQconnectdb(conninfo);
    if (PQstatus(db->conn) != CONNECTION_OK) {
        fprintf(stderr, "krl_db_open: %s\n", PQerrorMessage(db->conn));
        PQfinish(db->conn);
        free(db);
        return NULL;
    }
    return db;
}

void krl_db_close(KrlDb *db) {
    if (!db) return;
    PQfinish(db->conn);
    free(db);
}

int krl_db_migrate(KrlDb *db) {
    const char *ddl =
        "CREATE TABLE IF NOT EXISTS krul_projects ("
        "  id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE,"
        "  root_path TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

        "CREATE TABLE IF NOT EXISTS tasks ("
        "  id BIGSERIAL PRIMARY KEY, kind TEXT NOT NULL,"
        "  state TEXT NOT NULL DEFAULT 'pending',"
        "  params JSONB NOT NULL DEFAULT '{}',"
        "  stdout_tail TEXT, exit_code INT, result JSONB,"
        "  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "  started_at TIMESTAMPTZ, completed_at TIMESTAMPTZ);"

        "CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state);"
        "CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at DESC);"

        "CREATE TABLE IF NOT EXISTS entities ("
        "  id BIGSERIAL PRIMARY KEY,"
        "  project_id BIGINT NOT NULL REFERENCES krul_projects(id) ON DELETE CASCADE,"
        "  kind TEXT NOT NULL, name TEXT NOT NULL,"
        "  file_path TEXT NOT NULL, line_start INT NOT NULL DEFAULT 1,"
        "  line_end INT NOT NULL DEFAULT 1, confidence FLOAT NOT NULL DEFAULT 1.0,"
        "  indexed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "  UNIQUE (project_id, kind, name, file_path, line_start));"

        "CREATE INDEX IF NOT EXISTS idx_entities_project ON entities(project_id);"
        "CREATE INDEX IF NOT EXISTS idx_entities_kind    ON entities(project_id, kind);"
        "CREATE INDEX IF NOT EXISTS idx_entities_name    ON entities(project_id, name);"
        "CREATE INDEX IF NOT EXISTS idx_entities_file    ON entities(project_id, file_path);"

        "CREATE TABLE IF NOT EXISTS relationships ("
        "  id BIGSERIAL PRIMARY KEY,"
        "  project_id BIGINT NOT NULL REFERENCES krul_projects(id) ON DELETE CASCADE,"
        "  kind TEXT NOT NULL,"
        "  from_entity_id BIGINT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,"
        "  to_entity_id   BIGINT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,"
        "  confidence FLOAT NOT NULL DEFAULT 1.0,"
        "  indexed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "  UNIQUE (project_id, kind, from_entity_id, to_entity_id));"

        "CREATE INDEX IF NOT EXISTS idx_rel_from ON relationships(from_entity_id);"
        "CREATE INDEX IF NOT EXISTS idx_rel_to   ON relationships(to_entity_id);"
        "CREATE INDEX IF NOT EXISTS idx_rel_kind ON relationships(project_id, kind);";

    PGresult *res = PQexec(db->conn, ddl);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok)
        fprintf(stderr, "krl_db_migrate: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

/* ── Task queue ─────────────────────────────────────────────────────────────── */

int krl_task_insert(KrlDb *db, const char *kind, const char *params_json,
                    int64_t *task_id_out) {
    const char *sql =
        "INSERT INTO tasks(kind, params) VALUES($1, $2::jsonb) RETURNING id";
    const char *params[2] = { kind, params_json };
    PGresult *res = PQexecParams(db->conn, sql, 2, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "krl_task_insert: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        return -1;
    }
    *task_id_out = atoll(PQgetvalue(res, 0, 0));
    PQclear(res);
    return 0;
}

int krl_task_start(KrlDb *db, int64_t task_id) {
    const char *sql =
        "UPDATE tasks SET state='running', started_at=NOW() WHERE id=$1";
    char id_str[24];
    snprintf(id_str, sizeof(id_str), "%lld", (long long)task_id);
    const char *params[1] = { id_str };
    PGresult *res = PQexecParams(db->conn, sql, 1, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "krl_task_start: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

int krl_task_done(KrlDb *db, int64_t task_id, int exit_code,
                  const char *stdout_tail) {
    const char *sql =
        "UPDATE tasks SET state='done', exit_code=$2, stdout_tail=$3,"
        " completed_at=NOW() WHERE id=$1";
    char id_str[24], code_str[12];
    snprintf(id_str,   sizeof(id_str),   "%lld", (long long)task_id);
    snprintf(code_str, sizeof(code_str), "%d",   exit_code);
    const char *params[3] = { id_str, code_str, stdout_tail };
    PGresult *res = PQexecParams(db->conn, sql, 3, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "krl_task_done: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

int krl_task_fail(KrlDb *db, int64_t task_id, const char *err_msg) {
    const char *sql =
        "UPDATE tasks SET state='failed', stdout_tail=$2,"
        " completed_at=NOW() WHERE id=$1";
    char id_str[24];
    snprintf(id_str, sizeof(id_str), "%lld", (long long)task_id);
    const char *params[2] = { id_str, err_msg };
    PGresult *res = PQexecParams(db->conn, sql, 2, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "krl_task_fail: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

int krl_task_list_json(KrlDb *db, int limit, char *out, size_t out_size) {
    const char *sql =
        "SELECT json_agg(t) FROM ("
        "  SELECT id, kind, state, exit_code,"
        "    to_char(created_at,'YYYY-MM-DD\"T\"HH24:MI:SSZ') AS created_at,"
        "    to_char(completed_at,'YYYY-MM-DD\"T\"HH24:MI:SSZ') AS completed_at"
        "  FROM tasks ORDER BY created_at DESC LIMIT $1"
        ") t";
    char lim_str[12];
    snprintf(lim_str, sizeof(lim_str), "%d", limit);
    const char *params[1] = { lim_str };
    PGresult *res = PQexecParams(db->conn, sql, 1, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "krl_task_list_json: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        snprintf(out, out_size, "[]");
        return -1;
    }
    const char *json = PQgetvalue(res, 0, 0);
    if (!json || PQgetisnull(res, 0, 0)) {
        snprintf(out, out_size, "[]");
    } else {
        snprintf(out, out_size, "%s", json);
    }
    PQclear(res);
    return 0;
}

/* ── Project management ──────────────────────────────────────────────────────── */

int64_t krl_project_get_or_create(KrlDb *db, const char *name,
                                   const char *root_path) {
    /* Try SELECT first */
    const char *sel = "SELECT id FROM krul_projects WHERE name=$1";
    const char *sel_params[1] = { name };
    PGresult *res = PQexecParams(db->conn, sel, 1, NULL, sel_params, NULL, NULL, 0);
    if (PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) > 0) {
        int64_t id = atoll(PQgetvalue(res, 0, 0));
        PQclear(res);
        return id;
    }
    PQclear(res);

    /* INSERT ... ON CONFLICT DO NOTHING RETURNING id */
    const char *ins =
        "INSERT INTO krul_projects(name, root_path) VALUES($1,$2)"
        " ON CONFLICT(name) DO UPDATE SET root_path=EXCLUDED.root_path RETURNING id";
    const char *ins_params[2] = { name, root_path };
    res = PQexecParams(db->conn, ins, 2, NULL, ins_params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "krl_project_get_or_create: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        return -1;
    }
    int64_t id = atoll(PQgetvalue(res, 0, 0));
    PQclear(res);
    return id;
}

/* ── Entity management ───────────────────────────────────────────────────────── */

int krl_entity_insert(KrlDb *db, int64_t project_id, const char *kind,
                      const char *name, const char *file_path,
                      int line_start, int line_end, float confidence,
                      int64_t *entity_id_out) {
    const char *sql =
        "INSERT INTO entities(project_id, kind, name, file_path, line_start, line_end, confidence)"
        " VALUES($1,$2,$3,$4,$5,$6,$7)"
        " ON CONFLICT DO NOTHING RETURNING id";
    char proj_str[24], ls_str[12], le_str[12], conf_str[16];
    snprintf(proj_str, sizeof(proj_str), "%lld", (long long)project_id);
    snprintf(ls_str,   sizeof(ls_str),   "%d",   line_start);
    snprintf(le_str,   sizeof(le_str),   "%d",   line_end);
    snprintf(conf_str, sizeof(conf_str), "%.4f", (double)confidence);
    const char *params[7] = { proj_str, kind, name, file_path, ls_str, le_str, conf_str };
    PGresult *res = PQexecParams(db->conn, sql, 7, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "krl_entity_insert: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        return -1;
    }
    if (entity_id_out) {
        *entity_id_out = (PQntuples(res) > 0) ? atoll(PQgetvalue(res, 0, 0)) : 0;
    }
    PQclear(res);
    return 0;
}

int krl_entities_delete_file(KrlDb *db, int64_t project_id,
                              const char *file_path) {
    const char *sql = "DELETE FROM entities WHERE project_id=$1 AND file_path=$2";
    char proj_str[24];
    snprintf(proj_str, sizeof(proj_str), "%lld", (long long)project_id);
    const char *params[2] = { proj_str, file_path };
    PGresult *res = PQexecParams(db->conn, sql, 2, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "krl_entities_delete_file: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

/* ── Relation insertion ──────────────────────────────────────────────────────── */

int krl_relation_insert(KrlDb *db, int64_t project_id,
                        const char *kind,
                        const char *from_kind, const char *from_name,
                        const char *to_kind,   const char *to_name,
                        float confidence) {
    /* Resolve from-entity id */
    const char *from_sql =
        "SELECT id FROM entities WHERE project_id=$1 AND kind=$2 AND name=$3 LIMIT 1";
    char proj_str[24];
    snprintf(proj_str, sizeof(proj_str), "%lld", (long long)project_id);
    const char *fp[3] = { proj_str, from_kind, from_name };
    PGresult *r = PQexecParams(db->conn, from_sql, 3, NULL, fp, NULL, NULL, 0);
    if (PQresultStatus(r) != PGRES_TUPLES_OK || PQntuples(r) == 0) {
        PQclear(r); return 0; /* benign: endpoint not yet indexed */
    }
    char from_id_str[24];
    snprintf(from_id_str, sizeof(from_id_str), "%s", PQgetvalue(r, 0, 0));
    PQclear(r);

    /* Resolve to-entity id */
    const char *to_sql =
        "SELECT id FROM entities WHERE project_id=$1 AND kind=$2 AND name=$3 LIMIT 1";
    const char *tp[3] = { proj_str, to_kind, to_name };
    r = PQexecParams(db->conn, to_sql, 3, NULL, tp, NULL, NULL, 0);
    if (PQresultStatus(r) != PGRES_TUPLES_OK || PQntuples(r) == 0) {
        PQclear(r); return 0;
    }
    char to_id_str[24];
    snprintf(to_id_str, sizeof(to_id_str), "%s", PQgetvalue(r, 0, 0));
    PQclear(r);

    const char *sql =
        "INSERT INTO relationships(project_id,kind,from_entity_id,to_entity_id,confidence)"
        " VALUES($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING";
    char conf_str[16];
    snprintf(conf_str, sizeof(conf_str), "%.4f", (double)confidence);
    const char *params[5] = { proj_str, kind, from_id_str, to_id_str, conf_str };
    r = PQexecParams(db->conn, sql, 5, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(r) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "krl_relation_insert: %s\n", PQerrorMessage(db->conn));
    PQclear(r);
    return ok ? 0 : -1;
}

/* ── Plugin record ingestion ─────────────────────────────────────────────────── */

/* Minimal flat-JSON string extractor (no heap). Returns pointer into src. */
static const char *db_json_str(const char *src, const char *key, size_t *out_len) {
    char needle[64];
    int n = snprintf(needle, sizeof needle, "\"%s\":\"", key);
    if (n <= 0 || (size_t)n >= sizeof needle) return NULL;
    const char *p = strstr(src, needle);
    if (!p) return NULL;
    p += n;
    const char *end = strchr(p, '"');
    if (!end) return NULL;
    *out_len = (size_t)(end - p);
    return p;
}

static int db_json_int(const char *src, const char *key) {
    char needle[64];
    snprintf(needle, sizeof needle, "\"%s\":", key);
    const char *p = strstr(src, needle);
    if (!p) return 0;
    return atoi(p + strlen(needle));
}

static float db_json_float(const char *src, const char *key) {
    char needle[64];
    snprintf(needle, sizeof needle, "\"%s\":", key);
    const char *p = strstr(src, needle);
    if (!p) return 0.5f;
    return (float)atof(p + strlen(needle));
}

/* Copy at most dst_size-1 bytes from (src, len) into dst and null-terminate. */
static int copy_field(const char *src, size_t len, char *dst, size_t dst_size) {
    if (!src || len == 0 || len >= dst_size) return -1;
    memcpy(dst, src, len);
    dst[len] = '\0';
    return 0;
}

int krl_ingest_record(KrlDb *db, int64_t project_id, const char *line) {
    size_t type_len = 0;
    const char *type_val = db_json_str(line, "type", &type_len);
    if (!type_val) return -1;

    const int is_entity = (type_len == 6 && memcmp(type_val, "entity", 6) == 0);

    if (is_entity) {
        size_t kind_len = 0, name_len = 0, file_len = 0;
        const char *kind_val = db_json_str(line, "kind", &kind_len);
        const char *name_val = db_json_str(line, "name", &name_len);
        const char *file_val = db_json_str(line, "file", &file_len);

        char kind[64], name[256], file[4096];
        if (copy_field(kind_val, kind_len, kind, sizeof kind) < 0) return -1;
        if (copy_field(name_val, name_len, name, sizeof name) < 0) return -1;
        if (copy_field(file_val, file_len, file, sizeof file) < 0) return -1;

        int line_start = db_json_int(line, "line_start");
        if (line_start < 1) line_start = 1;
        float conf = db_json_float(line, "confidence");

        int64_t eid = 0;
        return krl_entity_insert(db, project_id, kind, name, file,
                                  line_start, line_start, conf, &eid);
    } else {
        size_t rk_len=0, fk_len=0, fn_len=0, tk_len=0, tn_len=0;
        const char *rk = db_json_str(line, "kind",      &rk_len);
        const char *fk = db_json_str(line, "from_kind", &fk_len);
        const char *fn = db_json_str(line, "from_name", &fn_len);
        const char *tk = db_json_str(line, "to_kind",   &tk_len);
        const char *tn = db_json_str(line, "to_name",   &tn_len);

        char kind[64], from_kind[64], from_name[256], to_kind[64], to_name[256];
        if (copy_field(rk, rk_len, kind,      sizeof kind)      < 0) return -1;
        if (copy_field(fk, fk_len, from_kind, sizeof from_kind) < 0) return -1;
        if (copy_field(fn, fn_len, from_name, sizeof from_name) < 0) return -1;
        if (copy_field(tk, tk_len, to_kind,   sizeof to_kind)   < 0) return -1;
        if (copy_field(tn, tn_len, to_name,   sizeof to_name)   < 0) return -1;

        float conf = db_json_float(line, "confidence");
        return krl_relation_insert(db, project_id, kind,
                                    from_kind, from_name,
                                    to_kind,   to_name, conf);
    }
}

/* ── Shell execution ─────────────────────────────────────────────────────────── */

int krl_exec_shell(const char *cmd, char *stdout_out, size_t out_size,
                   int *exit_code_out) {
    FILE *fp = popen(cmd, "r");
    if (!fp) {
        *exit_code_out = -1;
        if (out_size > 0) stdout_out[0] = '\0';
        return -1;
    }
    size_t n = fread(stdout_out, 1, out_size - 1, fp);
    stdout_out[n] = '\0';
    int status = pclose(fp);
    *exit_code_out = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return 0;
}

/* ── Project lookup ──────────────────────────────────────────────────────────── */

int64_t krl_project_lookup(KrlDb *db, const char *name) {
    const char *sql = "SELECT id FROM krul_projects WHERE name=$1";
    const char *params[1] = { name };
    PGresult *res = PQexecParams(db->conn, sql, 1, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) == 0) {
        PQclear(res);
        return -1;
    }
    int64_t id = atoll(PQgetvalue(res, 0, 0));
    PQclear(res);
    return id;
}

/* ── Gothos bundled query API ────────────────────────────────────────────────── */

int krl_gothos_query_entities(KrlDb *db, int64_t project_id,
                               const char *kind, const char *name_pattern,
                               char *out, size_t out_size) {
    char proj_str[24];
    snprintf(proj_str, sizeof(proj_str), "%lld", (long long)project_id);
    /* NULL param → SQL NULL → filter disabled via "IS NULL OR col=$N" pattern. */
    const char *sql =
        "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)::text FROM ("
        "  SELECT id, kind, name, file_path, line_start, confidence"
        "  FROM entities WHERE project_id=$1"
        "    AND ($2::text IS NULL OR kind=$2)"
        "    AND ($3::text IS NULL OR name ILIKE $3)"
        "  ORDER BY name LIMIT 100"
        ") t";
    const char *params[3] = { proj_str, kind, name_pattern };
    PGresult *res = PQexecParams(db->conn, sql, 3, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "query_entities: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        snprintf(out, out_size, "[]");
        return -1;
    }
    const char *json = PQgetvalue(res, 0, 0);
    snprintf(out, out_size, "%s", json ? json : "[]");
    PQclear(res);
    return 0;
}

int krl_gothos_query_relations(KrlDb *db, int64_t project_id,
                                const char *from_name, const char *rel_kind,
                                char *out, size_t out_size) {
    char proj_str[24];
    snprintf(proj_str, sizeof(proj_str), "%lld", (long long)project_id);
    const char *sql =
        "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)::text FROM ("
        "  SELECT r.kind, ef.name AS from_name, ef.kind AS from_kind,"
        "         et.name AS to_name, et.kind AS to_kind, r.confidence"
        "  FROM relationships r"
        "  JOIN entities ef ON r.from_entity_id=ef.id"
        "  JOIN entities et ON r.to_entity_id=et.id"
        "  WHERE r.project_id=$1"
        "    AND ($2::text IS NULL OR ef.name=$2)"
        "    AND ($3::text IS NULL OR r.kind=$3)"
        "  LIMIT 200"
        ") t";
    const char *params[3] = { proj_str, from_name, rel_kind };
    PGresult *res = PQexecParams(db->conn, sql, 3, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "query_relations: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        snprintf(out, out_size, "[]");
        return -1;
    }
    const char *json = PQgetvalue(res, 0, 0);
    snprintf(out, out_size, "%s", json ? json : "[]");
    PQclear(res);
    return 0;
}

int krl_gothos_get_context(KrlDb *db, int64_t project_id,
                            const char *focus_name, int depth,
                            char *out, size_t out_size) {
    (void)depth; /* depth > 1 reserved for future multi-hop traversal */
    char proj_str[24], focus_id_str[24];
    snprintf(proj_str, sizeof(proj_str), "%lld", (long long)project_id);

    /* Resolve focus entity → id */
    const char *id_sql =
        "SELECT id FROM entities WHERE project_id=$1 AND name=$2 LIMIT 1";
    const char *id_p[2] = { proj_str, focus_name };
    PGresult *r = PQexecParams(db->conn, id_sql, 2, NULL, id_p, NULL, NULL, 0);
    if (PQresultStatus(r) != PGRES_TUPLES_OK || PQntuples(r) == 0) {
        PQclear(r);
        snprintf(out, out_size,
                 "{\"entities\":[],\"relations\":[],\"error\":\"entity not found\"}");
        return 0;
    }
    snprintf(focus_id_str, sizeof(focus_id_str), "%s", PQgetvalue(r, 0, 0));
    PQclear(r);

    /* Get all relations involving the focus entity (both directions) */
    const char *rel_sql =
        "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)::text FROM ("
        "  SELECT r.kind, ef.name AS from_name, ef.kind AS from_kind,"
        "         et.name AS to_name, et.kind AS to_kind, r.confidence"
        "  FROM relationships r"
        "  JOIN entities ef ON r.from_entity_id=ef.id"
        "  JOIN entities et ON r.to_entity_id=et.id"
        "  WHERE r.project_id=$1"
        "    AND (r.from_entity_id=$2::bigint OR r.to_entity_id=$2::bigint)"
        ") t";
    const char *rel_p[2] = { proj_str, focus_id_str };
    r = PQexecParams(db->conn, rel_sql, 2, NULL, rel_p, NULL, NULL, 0);
    char rels[16384];
    if (PQresultStatus(r) != PGRES_TUPLES_OK) {
        snprintf(rels, sizeof(rels), "[]");
    } else {
        const char *rj = PQgetvalue(r, 0, 0);
        snprintf(rels, sizeof(rels), "%s", rj ? rj : "[]");
    }
    PQclear(r);

    /* Get focus entity + all direct neighbors */
    const char *ent_sql =
        "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)::text FROM ("
        "  SELECT DISTINCT e.id, e.kind, e.name, e.file_path, e.line_start, e.confidence"
        "  FROM entities e WHERE e.project_id=$1 AND ("
        "    e.id=$2::bigint"
        "    OR e.id IN (SELECT from_entity_id FROM relationships"
        "                WHERE project_id=$1 AND to_entity_id=$2::bigint)"
        "    OR e.id IN (SELECT to_entity_id FROM relationships"
        "                WHERE project_id=$1 AND from_entity_id=$2::bigint)"
        "  )"
        ") t";
    const char *ent_p[2] = { proj_str, focus_id_str };
    r = PQexecParams(db->conn, ent_sql, 2, NULL, ent_p, NULL, NULL, 0);
    char ents[16384];
    if (PQresultStatus(r) != PGRES_TUPLES_OK) {
        snprintf(ents, sizeof(ents), "[]");
    } else {
        const char *ej = PQgetvalue(r, 0, 0);
        snprintf(ents, sizeof(ents), "%s", ej ? ej : "[]");
    }
    PQclear(r);

    snprintf(out, out_size, "{\"entities\":%s,\"relations\":%s}", ents, rels);
    return 0;
}

int krl_gothos_no_covergroup(KrlDb *db, int64_t project_id,
                              char *out, size_t out_size) {
    char proj_str[24];
    snprintf(proj_str, sizeof(proj_str), "%lld", (long long)project_id);
    const char *sql =
        "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)::text FROM ("
        "  SELECT e.name, e.kind, e.file_path FROM entities e"
        "  WHERE e.project_id=$1 AND e.kind='UVM_AGENT'"
        "    AND NOT EXISTS ("
        "      SELECT 1 FROM relationships r"
        "      WHERE r.project_id=$1 AND r.kind='HAS_COVERGROUP'"
        "        AND r.from_entity_id=e.id"
        "    )"
        "  ORDER BY e.name"
        ") t";
    const char *params[1] = { proj_str };
    PGresult *res = PQexecParams(db->conn, sql, 1, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "no_covergroup: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        snprintf(out, out_size, "[]");
        return -1;
    }
    const char *json = PQgetvalue(res, 0, 0);
    snprintf(out, out_size, "%s", json ? json : "[]");
    PQclear(res);
    return 0;
}

/* ── Kanban task board ───────────────────────────────────────────────────────── */

int krl_kanban_migrate(KrlDb *db) {
    const char *ddl =
        "CREATE TABLE IF NOT EXISTS kanban_tasks ("
        "  id           TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,"
        "  title        TEXT NOT NULL,"
        "  body         TEXT,"
        "  status       TEXT NOT NULL DEFAULT 'triage'"
        "    CONSTRAINT kanban_status CHECK (status IN ("
        "      'triage','todo','ready','running','blocked','review','done','archived')),"
        "  priority     INTEGER NOT NULL DEFAULT 50,"
        "  created_by   TEXT,"
        "  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "  started_at   TIMESTAMPTZ,"
        "  completed_at TIMESTAMPTZ,"
        "  gear_name    TEXT,"
        "  gear_run_id  BIGINT,"
        "  linked_finding_id BIGINT);"

        "CREATE TABLE IF NOT EXISTS kanban_task_links ("
        "  parent_id TEXT NOT NULL REFERENCES kanban_tasks(id) ON DELETE CASCADE,"
        "  child_id  TEXT NOT NULL REFERENCES kanban_tasks(id) ON DELETE CASCADE,"
        "  PRIMARY KEY (parent_id, child_id));"

        "CREATE TABLE IF NOT EXISTS kanban_events ("
        "  id         BIGSERIAL PRIMARY KEY,"
        "  task_id    TEXT NOT NULL REFERENCES kanban_tasks(id) ON DELETE CASCADE,"
        "  kind       TEXT NOT NULL,"
        "  payload    JSONB,"
        "  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

        "CREATE INDEX IF NOT EXISTS idx_kanban_status ON kanban_tasks(status);"
        "CREATE INDEX IF NOT EXISTS idx_kanban_gear   ON kanban_tasks(gear_name);"
        "CREATE INDEX IF NOT EXISTS idx_kanban_events"
        "  ON kanban_events(task_id, created_at DESC);";

    PGresult *res = PQexec(db->conn, ddl);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "krl_kanban_migrate: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

int krl_kanban_add(KrlDb *db, const char *title, const char *body,
                   const char *gear_name, int priority,
                   char *task_id_out, size_t task_id_size) {
    const char *sql =
        "INSERT INTO kanban_tasks(title,body,gear_name,priority)"
        " VALUES($1,$2,$3,$4) RETURNING id";
    char prio_str[12];
    snprintf(prio_str, sizeof(prio_str), "%d", priority);
    const char *params[4] = { title, body, gear_name, prio_str };
    PGresult *res = PQexecParams(db->conn, sql, 4, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "krl_kanban_add: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        return -1;
    }
    snprintf(task_id_out, task_id_size, "%s", PQgetvalue(res, 0, 0));
    PQclear(res);

    const char *ev_sql =
        "INSERT INTO kanban_events(task_id,kind) VALUES($1,'created')";
    const char *ev_p[1] = { task_id_out };
    res = PQexecParams(db->conn, ev_sql, 1, NULL, ev_p, NULL, NULL, 0);
    PQclear(res);
    return 0;
}

int krl_kanban_list(KrlDb *db, const char *status, int limit,
                    char *out, size_t out_size) {
    char lim_str[12];
    snprintf(lim_str, sizeof(lim_str), "%d", limit > 0 ? limit : 50);
    const char *sql =
        "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)::text FROM ("
        "  SELECT id,title,status,priority,gear_name,created_at,completed_at"
        "  FROM kanban_tasks"
        "  WHERE ($1::text IS NULL OR status=$1)"
        "  ORDER BY priority DESC, created_at DESC LIMIT $2"
        ") t";
    const char *params[2] = { status, lim_str };
    PGresult *res = PQexecParams(db->conn, sql, 2, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "krl_kanban_list: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        snprintf(out, out_size, "[]");
        return -1;
    }
    const char *jval = PQgetvalue(res, 0, 0);
    snprintf(out, out_size, "%s", jval ? jval : "[]");
    PQclear(res);
    return 0;
}

int krl_kanban_get(KrlDb *db, const char *task_id, char *out, size_t out_size) {
    const char *sql =
        "SELECT row_to_json(t)::text FROM ("
        "  SELECT k.*,"
        "    (SELECT json_agg(row_to_json(e) ORDER BY e.created_at)"
        "     FROM kanban_events e WHERE e.task_id=k.id) AS events"
        "  FROM kanban_tasks k WHERE k.id=$1"
        ") t";
    const char *params[1] = { task_id };
    PGresult *res = PQexecParams(db->conn, sql, 1, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) == 0) {
        PQclear(res);
        snprintf(out, out_size, "null");
        return -1;
    }
    const char *jval = PQgetvalue(res, 0, 0);
    snprintf(out, out_size, "%s", jval ? jval : "null");
    PQclear(res);
    return 0;
}

int krl_kanban_move(KrlDb *db, const char *task_id, const char *new_status,
                    char *out, size_t out_size) {
    const char *sql =
        "UPDATE kanban_tasks SET status=$2,"
        "  started_at   = CASE WHEN $2='running' AND started_at IS NULL"
        "                      THEN NOW() ELSE started_at END,"
        "  completed_at = CASE WHEN $2 IN ('done','archived')"
        "                      THEN NOW() ELSE completed_at END"
        " WHERE id=$1";
    const char *params[2] = { task_id, new_status };
    PGresult *res = PQexecParams(db->conn, sql, 2, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "krl_kanban_move: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    if (!ok) { snprintf(out, out_size, "null"); return -1; }

    char payload[128];
    snprintf(payload, sizeof(payload), "{\"status\":\"%s\"}", new_status);
    const char *ev_sql =
        "INSERT INTO kanban_events(task_id,kind,payload)"
        " VALUES($1,'status_change',$2::jsonb)";
    const char *ev_p[2] = { task_id, payload };
    res = PQexecParams(db->conn, ev_sql, 2, NULL, ev_p, NULL, NULL, 0);
    PQclear(res);

    return krl_kanban_get(db, task_id, out, out_size);
}

int krl_kanban_link(KrlDb *db, const char *parent_id, const char *child_id) {
    const char *sql =
        "INSERT INTO kanban_task_links(parent_id,child_id)"
        " VALUES($1,$2) ON CONFLICT DO NOTHING";
    const char *params[2] = { parent_id, child_id };
    PGresult *res = PQexecParams(db->conn, sql, 2, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "krl_kanban_link: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}
