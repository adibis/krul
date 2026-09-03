#include "index.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <errno.h>

/* ── BIO label map ────────────────────────────────────────────────────────────
 * Matches the id2label in ~/azath-model/models/onnx/ner/config.json.
 * B- labels are odd; I- labels are even (>0). O = 0. */

static const char *label_kind(int label) {
    switch (label) {
        case  1: case  2: return "MODULE";
        case  3: case  4: return "INTERFACE";
        case  5: case  6: return "PACKAGE";
        case  7: case  8: return "PARAMETER";
        case  9: case 10: return "PORT";
        case 11: case 12: return "UVM_ENV";
        case 13: case 14: return "UVM_AGENT";
        case 15: case 16: return "UVM_DRIVER";
        case 17: case 18: return "UVM_MONITOR";
        case 19: case 20: return "UVM_SCOREBOARD";
        case 21: case 22: return "UVM_SEQUENCE";
        case 23: case 24: return "UVM_SEQ_ITEM";
        case 25: case 26: return "UVM_TEST";
        case 27: case 28: return "COVERGROUP";
        case 29: case 30: return "CLOCK_DOMAIN";
        default:           return NULL;
    }
}

/* Return 1 if label is a B- (begin) label. */
static int is_begin(int label) {
    return (label > 0) && (label % 2 == 1);
}

/* ── Source line-number helper ────────────────────────────────────────────────
 * Find the 1-based line number of the first occurrence of 'needle' in 'src'. */
static int find_line(const char *src, const char *needle) {
    const char *pos = strstr(src, needle);
    if (!pos) return 1;
    int line = 1;
    for (const char *p = src; p < pos; p++)
        if (*p == '\n') line++;
    return line;
}

/* ── Extension filter ─────────────────────────────────────────────────────────*/

static int is_sv_file(const char *name) {
    const char *dot = strrchr(name, '.');
    if (!dot) return 0;
    return strcmp(dot, ".sv")  == 0 ||
           strcmp(dot, ".v")   == 0 ||
           strcmp(dot, ".svh") == 0 ||
           strcmp(dot, ".uvm") == 0;
}

/* ── File reading helper ──────────────────────────────────────────────────────*/

static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    rewind(f);
    if (sz <= 0) { fclose(f); return NULL; }
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, (size_t)sz, f);
    buf[n] = '\0';
    fclose(f);
    if (out_len) *out_len = n;
    return buf;
}

/* ── Core: index one file ─────────────────────────────────────────────────────*/

int krl_index_file(KrlRuntime *rt, KrlTok *tok, KrlDb *db,
                   int64_t project_id, const char *file_path) {
    /* Read source */
    char *source = read_file(file_path, NULL);
    if (!source) {
        fprintf(stderr, "index: cannot read %s: %s\n", file_path, strerror(errno));
        return -1;
    }

    /* Tokenize (first KRL_MAX_SEQ tokens) */
    int64_t ids[KRL_MAX_SEQ], mask[KRL_MAX_SEQ];
    int seq_len = krl_tok_encode(tok, source, ids, mask, KRL_MAX_SEQ);
    if (seq_len < 2) {
        free(source);
        return 0;
    }

    /* NER */
    KrlNerResult ner = {0};
    if (krl_ner_run(rt, ids, mask, seq_len, &ner) != 0) {
        fprintf(stderr, "index: NER failed for %s\n", file_path);
        free(source);
        return -1;
    }

    /* Delete stale entities for this file before inserting fresh ones */
    krl_entities_delete_file(db, project_id, file_path);

    /* Extract BIO spans */
    int count = 0;
    for (int i = 1; i < ner.seq_len - 1; ) {
        int label = ner.labels[i];

        if (!is_begin(label)) { i++; continue; }

        /* Collect span: B- token plus following I- tokens */
        int span_start = i;
        int i_label    = label + 1;   /* corresponding I- label */
        i++;
        while (i < ner.seq_len - 1 && ner.labels[i] == i_label) i++;
        int span_end = i;   /* exclusive */

        /* Decode entity name */
        char name[128];
        int nlen = krl_tok_decode(tok, ids + span_start, span_end - span_start,
                                  name, sizeof(name));
        if (nlen <= 0 || name[0] == '\0') continue;

        const char *kind = label_kind(label);
        if (!kind) continue;

        float conf = ner.scores[span_start];
        int   line = find_line(source, name);

        int64_t eid = 0;
        if (krl_entity_insert(db, project_id, kind, name,
                              file_path, line, line, conf, &eid) == 0) {
            count++;
        }
    }

    krl_ner_result_free(&ner);
    free(source);

    if (count > 0)
        fprintf(stderr, "index: %s → %d entities\n", file_path, count);

    return count;
}

/* ── Recursive directory walker ───────────────────────────────────────────────*/

int krl_index_dir(KrlRuntime *rt, KrlTok *tok, KrlDb *db,
                  int64_t project_id, const char *dir_path) {
    DIR *d = opendir(dir_path);
    if (!d) {
        /* Silently skip missing directories (may not exist in every project) */
        return 0;
    }

    int total = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') continue;   /* skip hidden / . / .. */

        /* Build full path */
        char full[4096];
        snprintf(full, sizeof(full), "%s/%s", dir_path, ent->d_name);

        struct stat st;
        if (stat(full, &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            int r = krl_index_dir(rt, tok, db, project_id, full);
            if (r >= 0) total += r;
        } else if (S_ISREG(st.st_mode) && is_sv_file(ent->d_name)) {
            int r = krl_index_file(rt, tok, db, project_id, full);
            if (r >= 0) total += r;
        }
    }

    closedir(d);
    return total;
}
