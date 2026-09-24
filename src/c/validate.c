#include "validate.h"
#include <stdarg.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

/* ---------------------------------------------------------------------------
 * Minimal JSON field extractor — no heap allocation, no recursion.
 * Finds the value of a string field "key":"<value>" in a flat JSON object.
 * Returns pointer into src (not null-terminated); writes length to *out_len.
 * Returns NULL if field is absent.
 * --------------------------------------------------------------------------- */
static const char *json_str(const char *src, const char *key, size_t *out_len)
{
    char needle[64];
    int n = snprintf(needle, sizeof needle, "\"%s\":\"", key);
    if (n <= 0 || (size_t)n >= sizeof needle) return NULL;

    const char *p = strstr(src, needle);
    if (!p) return NULL;
    p += n; /* skip past opening quote of value */

    const char *end = strchr(p, '"');
    if (!end) return NULL;

    *out_len = (size_t)(end - p);
    return p;
}

/* ---------------------------------------------------------------------------
 * Ontology loading — one NDJSON record per line, read once at startup.
 * --------------------------------------------------------------------------- */
int krl_ontology_load(const char *path, KrlOntology *out)
{
    if (!path || !out) return -1;
    memset(out, 0, sizeof *out);

    FILE *f = fopen(path, "r");
    if (!f) return -1;

    char line[1024];
    while (fgets(line, sizeof line, f)) {
        /* Strip trailing newline. */
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
            line[--len] = '\0';
        }
        if (len == 0 || line[0] == '#') continue;

        size_t type_len = 0;
        const char *type_val = json_str(line, "type", &type_len);
        if (!type_val) continue;

        if (type_len == 11 && memcmp(type_val, "entity_kind", 11) == 0) {
            if (out->n_kinds >= KRL_ONTOLOGY_MAX_KINDS) {
                fclose(f);
                return -1;
            }
            size_t kind_len = 0, part_len = 0;
            const char *kind_val = json_str(line, "kind", &kind_len);
            const char *part_val = json_str(line, "partition", &part_len);
            if (!kind_val || !part_val) {
                fclose(f);
                return -1;
            }
            KrlOntologyKind *k = &out->kinds[out->n_kinds++];
            snprintf(k->kind, sizeof k->kind, "%.*s", (int)kind_len, kind_val);
            snprintf(k->partition, sizeof k->partition, "%.*s", (int)part_len, part_val);
        } else if (type_len == 13 && memcmp(type_val, "relation_kind", 13) == 0) {
            if (out->n_relations >= KRL_ONTOLOGY_MAX_RELATIONS) {
                fclose(f);
                return -1;
            }
            size_t kind_len = 0;
            const char *kind_val = json_str(line, "kind", &kind_len);
            if (!kind_val) {
                fclose(f);
                return -1;
            }
            snprintf(out->relations[out->n_relations++], 64, "%.*s",
                     (int)kind_len, kind_val);
        }
        /* Unknown "type" values are ignored, so an ontology file can grow
         * new record types later without breaking older krul builds. */
    }

    fclose(f);
    return 0;
}

static const char *expected_partition(const KrlOntology *ont, const char *kind, size_t klen)
{
    for (size_t i = 0; i < ont->n_kinds; i++) {
        const KrlOntologyKind *e = &ont->kinds[i];
        if (strlen(e->kind) == klen && memcmp(e->kind, kind, klen) == 0)
            return e->partition;
    }
    return NULL;
}

static int is_valid_relation_kind(const KrlOntology *ont, const char *kind, size_t klen)
{
    for (size_t i = 0; i < ont->n_relations; i++) {
        const char *rk = ont->relations[i];
        if (strlen(rk) == klen && memcmp(rk, kind, klen) == 0) return 1;
    }
    return 0;
}

/* ---------------------------------------------------------------------------
 * Error helper
 * --------------------------------------------------------------------------- */
static int fail(KrlValidateError *err, KrlRecordType rtype, int line_no,
                const char *fmt, ...)
{
    if (!err) return -1;
    err->record_type = rtype;
    err->line_no     = line_no;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err->message, sizeof err->message, fmt, ap);
    va_end(ap);
    return -1;
}

/* ---------------------------------------------------------------------------
 * Public API: validate one record
 * --------------------------------------------------------------------------- */
int krl_validate_record(const KrlOntology *ont, const char *line, int line_no,
                        KrlValidateError *err)
{
    if (!line || line[0] == '\0') {
        return fail(err, 0, line_no, "empty line");
    }
    if (line[0] != '{') {
        return fail(err, 0, line_no, "record must be a JSON object");
    }

    /* --- Determine record type ------------------------------------------- */
    size_t type_len = 0;
    const char *type_val = json_str(line, "type", &type_len);
    if (!type_val) {
        return fail(err, 0, line_no, "missing required field \"type\"");
    }

    int is_entity   = (type_len == 6 && memcmp(type_val, "entity",   6) == 0);
    int is_relation = (type_len == 8 && memcmp(type_val, "relation", 8) == 0);

    if (!is_entity && !is_relation) {
        return fail(err, 0, line_no,
                    "\"type\" must be \"entity\" or \"relation\", got \"%.*s\"",
                    (int)type_len, type_val);
    }

    KrlRecordType rtype = is_entity ? KRL_RECORD_ENTITY : KRL_RECORD_RELATION;

    /* --- Entity record validation ---------------------------------------- */
    if (is_entity) {
        /* Required string fields */
        const char *required[] = {
            "partition", "kind", "name", "file", NULL
        };
        for (int i = 0; required[i]; i++) {
            size_t vlen = 0;
            if (!json_str(line, required[i], &vlen) || vlen == 0) {
                return fail(err, rtype, line_no,
                            "entity record missing required field \"%s\"",
                            required[i]);
            }
        }

        /* confidence — look for numeric value (not quoted) */
        const char *conf_key = "\"confidence\":";
        if (!strstr(line, conf_key)) {
            return fail(err, rtype, line_no,
                        "entity record missing required field \"confidence\"");
        }

        /* line_start — look for numeric value */
        if (!strstr(line, "\"line_start\":")) {
            return fail(err, rtype, line_no,
                        "entity record missing required field \"line_start\"");
        }

        /* Partition/kind consistency */
        size_t part_len = 0, kind_len = 0;
        const char *part_val = json_str(line, "partition", &part_len);
        const char *kind_val = json_str(line, "kind",      &kind_len);

        /* kind enum check */
        const char *expected = expected_partition(ont, kind_val, kind_len);
        if (!expected) {
            return fail(err, rtype, line_no,
                        "unknown entity kind \"%.*s\"",
                        (int)kind_len, kind_val);
        }

        /* partition/kind mismatch (IC-1 equivalent) */
        if (strlen(expected) != part_len ||
            memcmp(expected, part_val, part_len) != 0) {
            return fail(err, rtype, line_no,
                        "kind \"%.*s\" belongs to partition \"%s\", "
                        "got \"%.*s\" (IC-1 violation)",
                        (int)kind_len, kind_val,
                        expected,
                        (int)part_len, part_val);
        }

        /* file must start with '/' (absolute path) */
        size_t file_len = 0;
        const char *file_val = json_str(line, "file", &file_len);
        if (file_len == 0 || file_val[0] != '/') {
            return fail(err, rtype, line_no,
                        "\"file\" must be an absolute path (starts with '/')");
        }

        return 0;
    }

    /* --- Relation record validation -------------------------------------- */
    static const char *rel_required[] = {
        "kind", "from_kind", "from_name", "to_kind", "to_name", NULL
    };
    for (int i = 0; rel_required[i]; i++) {
        size_t vlen = 0;
        if (!json_str(line, rel_required[i], &vlen) || vlen == 0) {
            return fail(err, rtype, line_no,
                        "relation record missing required field \"%s\"",
                        rel_required[i]);
        }
    }

    if (!strstr(line, "\"confidence\":")) {
        return fail(err, rtype, line_no,
                    "relation record missing required field \"confidence\"");
    }

    /* Relation kind enum check */
    size_t rk_len = 0;
    const char *rk_val = json_str(line, "kind", &rk_len);
    if (!is_valid_relation_kind(ont, rk_val, rk_len)) {
        return fail(err, rtype, line_no,
                    "unknown relation kind \"%.*s\"",
                    (int)rk_len, rk_val);
    }

    /* from_kind / to_kind must be known entity kinds */
    size_t fk_len = 0, tk_len = 0;
    const char *fk_val = json_str(line, "from_kind", &fk_len);
    const char *tk_val = json_str(line, "to_kind",   &tk_len);
    if (!expected_partition(ont, fk_val, fk_len)) {
        return fail(err, rtype, line_no,
                    "unknown from_kind \"%.*s\"", (int)fk_len, fk_val);
    }
    if (!expected_partition(ont, tk_val, tk_len)) {
        return fail(err, rtype, line_no,
                    "unknown to_kind \"%.*s\"", (int)tk_len, tk_val);
    }

    return 0;
}

/* ---------------------------------------------------------------------------
 * Public API: validate a complete plugin stdout buffer
 * --------------------------------------------------------------------------- */
int krl_validate_stream(const KrlOntology *ont, const char *buf, size_t len,
                        KrlValidateCb cb, void *userdata)
{
    int failures = 0;
    int line_no  = 0;
    const char *p   = buf;
    const char *end = buf + len;

    while (p < end) {
        const char *nl = memchr(p, '\n', (size_t)(end - p));
        const char *line_end = nl ? nl : end;
        size_t line_len = (size_t)(line_end - p);

        /* Copy line to null-terminate it (stack allocation, max 64KB) */
        if (line_len > 0 && line_len < 65536) {
            char *tmp = alloca(line_len + 1);
            memcpy(tmp, p, line_len);
            tmp[line_len] = '\0';

            line_no++;
            /* Skip blank lines and comment lines silently */
            if (tmp[0] != '\0' && tmp[0] != '#') {
                KrlValidateError err = {0};
                if (krl_validate_record(ont, tmp, line_no, &err) != 0) {
                    failures++;
                    if (cb) cb(&err, userdata);
                }
            }
        }

        p = nl ? nl + 1 : end;
    }

    return failures;
}
