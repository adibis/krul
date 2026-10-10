#pragma once
#include <stdint.h>
#include <stddef.h>

/* Opaque database handle */
typedef struct KrlDb KrlDb;

/* Open / close ----------------------------------------------------------------
 * conninfo: standard libpq connection string, e.g. "dbname=krul host=localhost"
 * Returns NULL on failure.  Thread-safe to call concurrently with different
 * KrlDb instances; do NOT share one KrlDb across threads. */
KrlDb *krl_db_open(const char *conninfo);
void   krl_db_close(KrlDb *db);

/* Apply DDL from schema/001_init.sql inline (idempotent).
 * Returns 0 on success, -1 on error. */
int krl_db_migrate(KrlDb *db);

/* Task queue -----------------------------------------------------------------
 * All functions return 0 on success, -1 on error.
 * task_id_out receives the new BIGSERIAL id on krl_task_insert(). */
int krl_task_insert(KrlDb *db, const char *kind, const char *params_json,
                    int64_t *task_id_out);
int krl_task_start(KrlDb *db, int64_t task_id);
int krl_task_done(KrlDb *db, int64_t task_id, int exit_code,
                  const char *stdout_tail);
int krl_task_fail(KrlDb *db, int64_t task_id, const char *err_msg);

/* Serialise the N most recent tasks as a JSON array into out[0..out_size-1].
 * Always null-terminates.  Returns 0 on success, -1 on error. */
int krl_task_list_json(KrlDb *db, int limit, char *out, size_t out_size);

/* Project management ---------------------------------------------------------
 * Returns project id (>0) on success, -1 on error. */
int64_t krl_project_get_or_create(KrlDb *db, const char *name,
                                   const char *root_path);

/* Entity insertion -----------------------------------------------------------
 * Inserts one NER-extracted entity; ON CONFLICT (project,file,kind,name,line)
 * DO NOTHING — safe to re-index.
 * entity_id_out receives the new or existing id.
 * Returns 0 on success, -1 on error. */
int krl_entity_insert(KrlDb *db, int64_t project_id, const char *kind,
                      const char *name, const char *file_path,
                      int line_start, int line_end, float confidence,
                      int64_t *entity_id_out);

/* Delete all entities for a given file (call before re-indexing). */
int krl_entities_delete_file(KrlDb *db, int64_t project_id,
                              const char *file_path);

/* Relation insertion ---------------------------------------------------------
 * Inserts one relation by resolving from_kind+from_name and to_kind+to_name
 * to entity ids within the project.  If either entity is not yet known the
 * relation is silently dropped (plugin may emit relations before both
 * endpoints are indexed in the same run; a follow-up index will wire them).
 * Returns 0 on success or benign miss, -1 on DB error. */
int krl_relation_insert(KrlDb *db, int64_t project_id,
                        const char *kind,
                        const char *from_kind, const char *from_name,
                        const char *to_kind,   const char *to_name,
                        float confidence);

/* Plugin record ingestion ----------------------------------------------------
 * Parses and inserts one validated entity or relation record (null-terminated
 * JSON line that has already passed krl_validate_record).
 * Returns 0 on success, -1 on parse or DB error. */
int krl_ingest_record(KrlDb *db, int64_t project_id, const char *line);

/* Shell execution ------------------------------------------------------------
 * Runs cmd via /bin/sh -c, captures stdout (up to out_size-1 bytes).
 * Always null-terminates stdout_out.
 * Writes WEXITSTATUS into *exit_code_out.
 * Returns 0 if the child process was launched and reaped (regardless of its
 * exit code), -1 if popen/pclose failed. */
int krl_exec_shell(const char *cmd, char *stdout_out, size_t out_size,
                   int *exit_code_out);

/* Runs path with argv[1..argc-1] directly via fork/exec, no shell involved --
 * argv entries reach the child exactly as given, so a gate script's inputs
 * can never be reinterpreted as shell syntax regardless of their content.
 * argv must be NULL-terminated per execv() convention; argv[0] is
 * conventionally path itself.
 * Writes WEXITSTATUS into *exit_code_out (or -1 if the child didn't exit
 * normally). Returns 0 if the child was launched and reaped, -1 if
 * fork/exec/wait itself failed. */
int krl_exec_argv(const char *path, char *const argv[], int *exit_code_out);

/* Project lookup -------------------------------------------------------------
 * Returns project id (>0) if a project with the given name exists, else -1. */
int64_t krl_project_lookup(KrlDb *db, const char *name);

/* Gothos bundled query API ---------------------------------------------------
 * All functions write a null-terminated JSON string into out[0..out_size-1].
 * Return 0 on success, -1 on error (out is set to a fallback value on error).
 *
 * NULL for optional filter parameters means "no filter" (match all). */
/* half_life_hours/strength_min/visibility_threshold come from krul.toml's
 * [decay] section (see config.zig); rows whose current decayed strength
 * falls below visibility_threshold are excluded here but remain reachable
 * via krl_entity_get_by_id() below, which never filters. */
int krl_gothos_query_entities(KrlDb *db, int64_t project_id,
                               const char *kind,         /* NULL = any */
                               const char *name_pattern, /* NULL = any, ILIKE */
                               double half_life_hours, double strength_min,
                               double visibility_threshold,
                               char *out, size_t out_size);

int krl_gothos_query_relations(KrlDb *db, int64_t project_id,
                                const char *from_name, /* NULL = any */
                                const char *rel_kind,  /* NULL = any */
                                double half_life_hours, double strength_min,
                                double visibility_threshold,
                                char *out, size_t out_size);

/* Direct by-id fetch, bypassing the strength/visibility filter entirely —
 * a row excluded from the default query.* results above is still reachable
 * this way, by design (see PLAN.md Phase 10's "Done when").
 * Returns 0 on success, -1 if id doesn't exist (out is set to "null"). */
int krl_entity_get_by_id(KrlDb *db, int64_t entity_id,
                          char *out, size_t out_size);

/* Returns {"entities":[...],"relations":[...]} centered on focus_name.
 * depth is accepted but currently only depth=1 (direct neighbors) is used. */
int krl_gothos_get_context(KrlDb *db, int64_t project_id,
                            const char *focus_name,
                            int depth,
                            char *out, size_t out_size);

/* Returns JSON array of UVM_AGENT entities that have no HAS_COVERGROUP edge. */
int krl_gothos_no_covergroup(KrlDb *db, int64_t project_id,
                              char *out, size_t out_size);

/* Kanban task board -----------------------------------------------------------
 * krl_kanban_migrate(): create tables if absent (idempotent). Returns 0/−1.
 *
 * krl_kanban_add(): insert a new task; writes the generated UUID into
 *   task_id_out[0..task_id_size-1] (null-terminated).  Returns 0/−1.
 *
 * krl_kanban_list(): JSON array of up to `limit` tasks matching `status`
 *   (NULL = any status).  Returns 0/−1.
 *
 * krl_kanban_get(): JSON object for one task by id.  Returns 0/−1.
 *
 * krl_kanban_move(): change task status; writes updated task JSON into out.
 *   Returns 0/−1.
 *
 * krl_kanban_link(): add a parent→child dependency link.  Returns 0/−1. */
int krl_kanban_migrate(KrlDb *db);

int krl_kanban_add(KrlDb *db, const char *title, const char *body,
                   const char *gear_name, int priority,
                   char *task_id_out, size_t task_id_size);

int krl_kanban_list(KrlDb *db, const char *status, /* NULL = any */
                    int limit, char *out, size_t out_size);

int krl_kanban_get(KrlDb *db, const char *task_id,
                   char *out, size_t out_size);

int krl_kanban_move(KrlDb *db, const char *task_id, const char *new_status,
                    char *out, size_t out_size);

int krl_kanban_link(KrlDb *db, const char *parent_id, const char *child_id);

/* Evaporation-based invalidation (Phase 10) -----------------------------------
 * Pheromone-style strength decay computed at read time; reinforcement resets
 * strength to 1.0 rather than incrementing it. See PLAN.md Phase 10.
 *
 * krl_evaporation_migrate(): add strength/last_reinforced_at columns to
 *   entities and relationships if absent (idempotent). Returns 0/-1.
 *
 * krl_reinforce_entity() / krl_reinforce_relation(): reset strength to 1.0
 *   and last_reinforced_at to now() for the given row. This is a blind SET,
 *   not a read-modify-write, so concurrent reinforcement of the same row
 *   cannot lose an update the way an increment-based counter could.
 *   Returns 0 on success, -1 on error (including id not found).
 *
 * krl_entity_strength() / krl_relation_strength(): compute the current
 *   decayed strength for one row, clamped to [strength_min, 1.0] — the
 *   MAX-MIN Ant System bound, so a long-neglected row never decays to a
 *   value indistinguishable from zero and unrecoverable without external
 *   re-indexing. half_life_hours and strength_min are caller-supplied (from
 *   krul.toml's [decay] section), not hardcoded.
 *   Returns 0 on success (*out is set), -1 on error (including id not found). */
int krl_evaporation_migrate(KrlDb *db);

int krl_reinforce_entity(KrlDb *db, int64_t entity_id);
int krl_reinforce_relation(KrlDb *db, int64_t relation_id);

int krl_entity_strength(KrlDb *db, int64_t entity_id,
                        double half_life_hours, double strength_min,
                        double *out);
int krl_relation_strength(KrlDb *db, int64_t relation_id,
                          double half_life_hours, double strength_min,
                          double *out);
