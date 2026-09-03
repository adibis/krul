#pragma once
#include <stdint.h>
#include <stddef.h>

/*
 * ONNX Runtime inference layer for krul.
 *
 * Two sessions are managed:
 *   NER session    — token classification, outputs one label per input token
 *   Encoder session — produces a single 768-dim embedding for the input
 *
 * Both use CPU execution. Calls are synchronous.
 */

#define KRL_EMBED_DIM  768

typedef struct KrlRuntime KrlRuntime;

/* NER output: one label per token position (in BIO scheme).
 * Indices correspond to the id2label mapping from the model config. */
typedef struct {
    int32_t  *labels;      /* length = seq_len; caller-owned */
    float    *scores;      /* confidence per token; caller-owned */
    int       seq_len;
} KrlNerResult;

/* Embedding output */
typedef struct {
    float embed[KRL_EMBED_DIM];
} KrlEmbed;

/* Load both sessions.
 * ner_path:     path to ner/model.onnx
 * encoder_path: path to encoder.onnx
 * Returns NULL on failure; call krl_runtime_free() when done. */
KrlRuntime *krl_runtime_load(const char *ner_path, const char *encoder_path);
void        krl_runtime_free(KrlRuntime *rt);

/* Run NER on a token sequence.
 * input_ids / attention_mask: int64_t arrays of length seq_len.
 * Result labels/scores are malloc'd by callee; caller frees them.
 * Returns 0 on success, -1 on error. */
int krl_ner_run(KrlRuntime     *rt,
                const int64_t  *input_ids,
                const int64_t  *attention_mask,
                int             seq_len,
                KrlNerResult   *out);

/* Run encoder to get a sequence-level embedding (pooled CLS representation).
 * Returns 0 on success, -1 on error. */
int krl_encode_run(KrlRuntime    *rt,
                   const int64_t *input_ids,
                   const int64_t *attention_mask,
                   int            seq_len,
                   KrlEmbed      *out);

void krl_ner_result_free(KrlNerResult *r);
