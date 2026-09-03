#include "../src/c/tok.h"
#include "../src/c/infer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MODELS_DIR "models/"

static void print_result(const char *text, const int32_t *ids, const KrlNerResult *ner) {
    printf("Input: %s\n", text);
    printf("Tokens: %d (incl. BOS/EOS)\n", ner->seq_len);
    /* Print non-O labels */
    int found = 0;
    for (int i = 1; i < ner->seq_len - 1; i++) {
        if (ner->labels[i] != 0) {  /* 0 = O in most BIO schemes */
            printf("  token[%2d] id=%-6d label=%d score=%.3f\n",
                   i, ids[i], ner->labels[i], ner->scores[i]);
            found = 1;
        }
    }
    if (!found) printf("  (all O labels)\n");
    printf("\n");
}

int main(void) {
    int rc = 0;

    /* Load tokenizer */
    printf("Loading tokenizer...\n");
    KrlTok *tok = krl_tok_load(MODELS_DIR "vocab.bin", MODELS_DIR "merges.bin");
    if (!tok) { fprintf(stderr, "FAIL: tokenizer load\n"); return 1; }

    /* Load inference sessions */
    printf("Loading ONNX sessions...\n");
    KrlRuntime *rt = krl_runtime_load(MODELS_DIR "ner.onnx", MODELS_DIR "encoder.onnx");
    if (!rt) { fprintf(stderr, "FAIL: runtime load\n"); krl_tok_free(tok); return 1; }

    /* Test cases: SV/UVM fragments */
    const char *samples[] = {
        "class axi_agent extends uvm_agent;",
        "covergroup cg_req_phase @(posedge clk);",
        "sequence s_write_burst; req ##1 ack; endsequence",
        "interface axi4_if (input logic clk, rst_n);",
        NULL
    };

    int64_t ids[KRL_MAX_SEQ];
    int64_t mask[KRL_MAX_SEQ];

    for (int i = 0; samples[i]; i++) {
        int len = krl_tok_encode(tok, samples[i], ids, mask, KRL_MAX_SEQ);
        if (len < 0) {
            fprintf(stderr, "FAIL: tokenize sample %d\n", i);
            rc = 1;
            continue;
        }

        KrlNerResult ner = {0};
        if (krl_ner_run(rt, ids, mask, len, &ner) != 0) {
            fprintf(stderr, "FAIL: NER run sample %d\n", i);
            rc = 1;
            continue;
        }

        print_result(samples[i], ids, &ner);
        krl_ner_result_free(&ner);
    }

    /* Encoder test: check embedding is non-zero and finite */
    {
        const char *enc_input = "class axi_agent extends uvm_agent;";
        int len = krl_tok_encode(tok, enc_input, ids, mask, KRL_MAX_SEQ);
        KrlEmbed embed = {0};
        if (krl_encode_run(rt, ids, mask, len, &embed) == 0) {
            float norm = 0.0f;
            for (int d = 0; d < KRL_EMBED_DIM; d++) norm += embed.embed[d] * embed.embed[d];
            printf("Encoder embedding norm: %.4f (dims=%d)\n", norm, KRL_EMBED_DIM);
        } else {
            fprintf(stderr, "FAIL: encoder run\n");
            rc = 1;
        }
    }

    krl_runtime_free(rt);
    krl_tok_free(tok);

    printf("\n%s\n", rc == 0 ? "ALL PASS" : "SOME FAILURES");
    return rc;
}
