#pragma once
#include <stddef.h>

/*
 * Plugin record validation — enforces schema/plugin_schema.json against
 * an ontology supplied at runtime, not a kind vocabulary baked into krul
 * itself. krul is a generic orchestrator; DV/UVM (ontologies/dv-uvm.json)
 * is one example plugin contract among others a gear can load.
 *
 * Called by the daemon for every line of plugin stdout before DB insertion.
 * Zero external dependencies — pure libc string scanning, no heap use in
 * the hot per-record path (ontology load is the one place that touches
 * stdio, and that only happens once at startup).
 */

typedef enum {
    KRL_RECORD_ENTITY   = 1,
    KRL_RECORD_RELATION = 2,
} KrlRecordType;

typedef struct {
    char         message[256]; /* human-readable reason */
    KrlRecordType record_type; /* 0 if type could not be determined */
    int          line_no;      /* 1-based line number within plugin stream */
} KrlValidateError;

/*
 * One entity kind known to an ontology, and the partition it belongs to.
 * "Partition" is just an ontology-defined grouping label (DV's ontology
 * uses structural/verification/coverage/register; a different ontology
 * is free to define its own).
 */
#define KRL_ONTOLOGY_MAX_KINDS     256
#define KRL_ONTOLOGY_MAX_RELATIONS 256

typedef struct {
    char kind[64];
    char partition[64];
} KrlOntologyKind;

typedef struct {
    KrlOntologyKind kinds[KRL_ONTOLOGY_MAX_KINDS];
    size_t          n_kinds;
    char            relations[KRL_ONTOLOGY_MAX_RELATIONS][64];
    size_t          n_relations;
} KrlOntology;

/*
 * Load an ontology from an NDJSON file: one JSON object per line, each
 * either {"type":"entity_kind","kind":"...","partition":"..."} or
 * {"type":"relation_kind","kind":"..."}. Blank lines and lines starting
 * with '#' are ignored.
 *
 * Returns 0 on success, -1 on error (file not found, malformed line, or
 * more kinds/relations than KRL_ONTOLOGY_MAX_* can hold).
 */
int krl_ontology_load(const char *path, KrlOntology *out);

/*
 * Validate one newline-delimited JSON record emitted by a plugin.
 *
 * ont      - the ontology to validate kind/partition/relation values against
 * line     - null-terminated JSON string (trailing newline stripped by caller)
 * line_no  - 1-based position in plugin stdout stream (for error messages)
 * err      - populated on failure; may be NULL if caller only needs pass/fail
 *
 * Returns 0 on success, -1 on validation error.
 */
int krl_validate_record(const KrlOntology *ont, const char *line, int line_no,
                        KrlValidateError *err);

/*
 * Convenience wrapper: validate every newline-terminated line in buf[0..len].
 * Calls cb(err, userdata) for each invalid line. Returns count of failures.
 */
typedef void (*KrlValidateCb)(const KrlValidateError *err, void *userdata);
int krl_validate_stream(const KrlOntology *ont, const char *buf, size_t len,
                        KrlValidateCb cb, void *userdata);
