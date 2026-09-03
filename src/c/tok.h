#pragma once
#include <stdint.h>
#include <stddef.h>

/*
 * Byte-level BPE tokenizer for krul.
 * Implements the RoBERTa tokenization scheme used by GraphCodeBERT.
 * Loads a binary vocabulary and merge table produced by tools/convert_tokenizer.py.
 *
 * Token layout after encode():
 *   [BOS=0] [token_ids...] [EOS=2]
 *
 * Maximum sequence length (including BOS/EOS) is KRL_MAX_SEQ.
 */

#define KRL_MAX_SEQ   512
#define KRL_TOK_BOS     0
#define KRL_TOK_PAD     1
#define KRL_TOK_EOS     2
#define KRL_TOK_UNK     3

typedef struct KrlTok KrlTok;

/* Load tokenizer data from pre-built binary files.
 * vocab_path: path to vocab.bin
 * merges_path: path to merges.bin
 * Returns NULL on failure. */
KrlTok *krl_tok_load(const char *vocab_path, const char *merges_path);
void    krl_tok_free(KrlTok *tok);

/* Decode token IDs back to text (best-effort for ASCII identifiers).
 * Strips the GPT-2 Ġ space-marker prefix from each token before concatenating.
 * out receives a null-terminated UTF-8 string.
 * Returns number of chars written (excluding null), or -1 on error. */
int krl_tok_decode(const KrlTok *tok,
                   const int64_t *ids,
                   int            n_ids,
                   char          *out,
                   int            out_size);

/* Encode a null-terminated UTF-8 string.
 * Writes token ids into out_ids (caller-allocated, capacity KRL_MAX_SEQ).
 * Writes attention mask (1 for real tokens, 0 for padding) into out_mask.
 * Both arrays hold int64_t to match ONNX model input types.
 * Returns number of tokens written (including BOS and EOS), or -1 on error. */
int krl_tok_encode(const KrlTok *tok,
                   const char   *text,
                   int64_t      *out_ids,
                   int64_t      *out_mask,
                   int           max_len);
