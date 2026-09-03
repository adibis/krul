/*
 * krul-indexer-codebert — built-in NER indexer plugin
 *
 * Modes (selected via argv):
 *   (default)         stdin: file paths → stdout: entity NDJSON
 *   --encode-server   stdin: text lines → stdout: {"embed":[...768 floats...]}
 *
 * argv[1] : optional models directory (overrides KRUL_MODELS env),
 *           OR the --encode-server flag if that is the only argument.
 * argv[2] : models directory when argv[1] is --encode-server.
 *
 * No DB access — the daemon validates and ingests stdout records.
 */

#include "infer.h"
#include "tok.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* ── BIO label tables ─────────────────────────────────────────────────────── */

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

static const char *label_partition(int label) {
    switch (label) {
        case 11: case 12:
        case 13: case 14:
        case 15: case 16:
        case 17: case 18:
        case 19: case 20:
        case 21: case 22:
        case 23: case 24:
        case 25: case 26: return "verification";
        case 27: case 28: return "coverage";
        default:           return "structural";
    }
}

static int is_begin(int label) {
    return (label > 0) && (label % 2 == 1);
}

/* ── Helpers ──────────────────────────────────────────────────────────────── */

static int find_line(const char *src, const char *needle) {
    const char *pos = strstr(src, needle);
    if (!pos) return 1;
    int line = 1;
    for (const char *p = src; p < pos; p++)
        if (*p == '\n') line++;
    return line;
}

/* JSON-escape s into buf; always null-terminates. Returns buf. */
static const char *json_escape(const char *s, char *buf, size_t buf_size) {
    size_t out = 0;
    for (size_t i = 0; s[i] && out + 4 < buf_size; i++) {
        unsigned char c = (unsigned char)s[i];
        if      (c == '"')  { buf[out++] = '\\'; buf[out++] = '"';  }
        else if (c == '\\') { buf[out++] = '\\'; buf[out++] = '\\'; }
        else if (c >= 0x20) { buf[out++] = (char)c; }
        /* skip control chars */
    }
    buf[out] = '\0';
    return buf;
}

/* ── Per-file indexing ────────────────────────────────────────────────────── */

static void index_file(KrlRuntime *rt, KrlTok *tok, const char *file_path) {
    FILE *f = fopen(file_path, "r");
    if (!f) {
        fprintf(stderr, "# skip %s: %s\n", file_path, strerror(errno));
        return;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    rewind(f);
    if (sz <= 0) { fclose(f); return; }

    char *source = malloc((size_t)sz + 1);
    if (!source) { fclose(f); return; }
    size_t n = fread(source, 1, (size_t)sz, f);
    source[n] = '\0';
    fclose(f);

    int64_t ids[KRL_MAX_SEQ], mask_arr[KRL_MAX_SEQ];
    int seq_len = krl_tok_encode(tok, source, ids, mask_arr, KRL_MAX_SEQ);
    if (seq_len < 2) { free(source); return; }

    KrlNerResult ner = {0};
    if (krl_ner_run(rt, ids, mask_arr, seq_len, &ner) != 0) {
        fprintf(stderr, "# ner error: %s\n", file_path);
        free(source);
        return;
    }

    char esc_file[4096], esc_name[256];
    json_escape(file_path, esc_file, sizeof esc_file);

    for (int i = 1; i < ner.seq_len - 1; ) {
        int label = ner.labels[i];
        if (!is_begin(label)) { i++; continue; }

        int span_start = i;
        int i_label    = label + 1;
        i++;
        while (i < ner.seq_len - 1 && ner.labels[i] == i_label) i++;

        char name[128];
        int nlen = krl_tok_decode(tok, ids + span_start, i - span_start,
                                  name, sizeof name);
        if (nlen <= 0 || name[0] == '\0') continue;

        const char *kind      = label_kind(label);
        const char *partition = label_partition(label);
        if (!kind) continue;

        float conf = ner.scores[span_start];
        int   line = find_line(source, name);

        json_escape(name, esc_name, sizeof esc_name);

        printf("{\"type\":\"entity\",\"partition\":\"%s\",\"kind\":\"%s\","
               "\"name\":\"%s\",\"file\":\"%s\",\"line_start\":%d,"
               "\"confidence\":%.4f}\n",
               partition, kind, esc_name, esc_file, line, (double)conf);
    }

    krl_ner_result_free(&ner);
    free(source);
    fflush(stdout);
}

/* ── Encode-server mode ───────────────────────────────────────────────────── */

/* Reads text lines from stdin; for each, emits {"embed":[...768 floats...]}.
 * Outputs {"embed":null} on tokenization or inference failure so the daemon
 * always gets one response per request and the protocol stays in sync. */
static int run_encode_server(KrlRuntime *rt, KrlTok *tok) {
    char line[8192];
    while (fgets(line, (int)sizeof line, stdin)) {
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
            line[--len] = '\0';
        if (len == 0) continue;

        int64_t ids[KRL_MAX_SEQ], mask[KRL_MAX_SEQ];
        int seq_len = krl_tok_encode(tok, line, ids, mask, KRL_MAX_SEQ);
        if (seq_len < 2) {
            fputs("{\"embed\":null}\n", stdout);
            fflush(stdout);
            continue;
        }

        KrlEmbed emb;
        if (krl_encode_run(rt, ids, mask, seq_len, &emb) != 0) {
            fputs("{\"embed\":null}\n", stdout);
            fflush(stdout);
            continue;
        }

        fputs("{\"embed\":[", stdout);
        for (int i = 0; i < KRL_EMBED_DIM; i++) {
            if (i > 0) fputc(',', stdout);
            fprintf(stdout, "%.6g", (double)emb.embed[i]);
        }
        fputs("]}\n", stdout);
        fflush(stdout);
    }
    return 0;
}

/* ── Entry point ──────────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    /* Scan argv for --encode-server flag and positional models directory. */
    int encode_server = 0;
    const char *models_dir = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--encode-server") == 0) {
            encode_server = 1;
        } else if (argv[i][0] != '-' && !models_dir) {
            models_dir = argv[i];
        }
    }
    if (!models_dir) models_dir = getenv("KRUL_MODELS");
    if (!models_dir || models_dir[0] == '\0') models_dir = "models";

    char ner_path[1024], enc_path[1024], voc_path[1024], mrg_path[1024];
    snprintf(ner_path, sizeof ner_path, "%s/ner.onnx",     models_dir);
    snprintf(enc_path, sizeof enc_path, "%s/encoder.onnx", models_dir);
    snprintf(voc_path, sizeof voc_path, "%s/vocab.bin",    models_dir);
    snprintf(mrg_path, sizeof mrg_path, "%s/merges.bin",   models_dir);

    KrlTok *tok = krl_tok_load(voc_path, mrg_path);
    if (!tok) {
        fprintf(stderr, "error: tokenizer load failed (%s, %s)\n",
                voc_path, mrg_path);
        return 1;
    }

    KrlRuntime *rt = krl_runtime_load(ner_path, enc_path);
    if (!rt) {
        krl_tok_free(tok);
        fprintf(stderr, "error: ONNX runtime load failed (%s, %s)\n",
                ner_path, enc_path);
        return 1;
    }

    int rc;
    if (encode_server) {
        rc = run_encode_server(rt, tok);
    } else {
        char line[4096];
        while (fgets(line, (int)sizeof line, stdin)) {
            size_t len = strlen(line);
            while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
                line[--len] = '\0';
            if (len == 0) continue;
            index_file(rt, tok, line);
        }
        rc = 0;
    }

    krl_runtime_free(rt);
    krl_tok_free(tok);
    return rc;
}
