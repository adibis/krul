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

/* Project lookup -------------------------------------------------------------
 * Returns project id (>0) if a project with the given name exists, else -1. */
int64_t krl_project_lookup(KrlDb *db, const char *name);

/* Gothos bundled query API ---------------------------------------------------
 * All functions write a null-terminated JSON string into out[0..out_size-1].
 * Return 0 on success, -1 on error (out is set to a fallback value on error).
 *
 * NULL for optional filter parameters means "no filter" (match all). */
int krl_gothos_query_entities(KrlDb *db, int64_t project_id,
                               const char *kind,         /* NULL = any */
                               const char *name_pattern, /* NULL = any, ILIKE */
                               char *out, size_t out_size);

int krl_gothos_query_relations(KrlDb *db, int64_t project_id,
                                const char *from_name, /* NULL = any */
                                const char *rel_kind,  /* NULL = any */
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
