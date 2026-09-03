#include "tok.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* ---- Binary file format ------------------------------------------------- */

/* vocab.bin:
 *   magic    4 bytes  "ICRV"
 *   version  4 bytes  1
 *   count    4 bytes  N
 *   for each entry (sorted by id, id 0..N-1):
 *     id     4 bytes
 *     len    2 bytes
 *     bytes  len bytes  (UTF-8 token string, no null)
 *
 * merges.bin:
 *   magic    4 bytes  "ICRM"
 *   version  4 bytes  1
 *   count    4 bytes  M
 *   for each entry (in merge priority order, rank 0 = highest priority):
 *     left   4 bytes  token id
 *     right  4 bytes  token id
 *     result 4 bytes  token id
 */

#define VOCAB_MAGIC "ICRV"
#define MERGE_MAGIC "ICRM"

/* ---- GPT-2 byte-to-unicode table ---------------------------------------- */

/* RoBERTa uses byte-level BPE. Each input byte is first mapped to a unicode
 * codepoint, then encoded as UTF-8, then looked up in the vocab.
 * The mapping table is the same one used in the original GPT-2 release. */
static uint32_t byte_to_unicode[256];
static int byte_table_init = 0;

static void init_byte_table(void) {
    if (byte_table_init) return;
    /* Printable ASCII range and a few others map to themselves */
    int n = 0;
    int bs[256] = {0};
    for (int c = '!'; c <= '~'; c++) { bs[n++] = c; byte_to_unicode[c] = (uint32_t)c; }
    for (int c = 0xA1; c <= 0xAC; c++) { bs[n++] = c; byte_to_unicode[c] = (uint32_t)c; }
    for (int c = 0xAE; c <= 0xFF; c++) { bs[n++] = c; byte_to_unicode[c] = (uint32_t)c; }

    /* Remaining bytes map to codepoints starting at 256 */
    uint32_t next_cp = 256;
    for (int b = 0; b < 256; b++) {
        int mapped = 0;
        for (int i = 0; i < n; i++) if (bs[i] == b) { mapped = 1; break; }
        if (!mapped) byte_to_unicode[b] = next_cp++;
    }
    byte_table_init = 1;
}

/* Encode a unicode codepoint as UTF-8, return bytes written (1-4). */
static int cp_to_utf8(uint32_t cp, char *out) {
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    } else if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    } else {
        out[0] = (char)(0xF0 | (cp >> 18));
        out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[3] = (char)(0x80 | (cp & 0x3F));
        return 4;
    }
}

/* ---- Vocabulary hash table ---------------------------------------------- */

#define VOCAB_HT_CAP (1 << 17)   /* 131072 slots; vocab is 50265 entries */

typedef struct VocabEntry {
    char     *str;    /* owned by the strings block */
    uint32_t  id;
    uint32_t  next;   /* chained index, 0 = end (0 is unused since id 0 is BOS) */
} VocabEntry;

typedef struct VocabHT {
    uint32_t    *buckets;   /* VOCAB_HT_CAP entries, 0 = empty */
    VocabEntry  *entries;
    uint32_t     count;
    char        *strings;   /* flat string storage */
} VocabHT;

static uint32_t ht_hash(const char *s, size_t len) {
    uint32_t h = 0x811c9dc5u;
    for (size_t i = 0; i < len; i++)
        h = (h ^ (unsigned char)s[i]) * 0x01000193u;
    return h;
}

static int ht_lookup(const VocabHT *ht, const char *str, size_t len, uint32_t *out_id) {
    uint32_t h = ht_hash(str, len) & (VOCAB_HT_CAP - 1);
    uint32_t idx = ht->buckets[h];
    while (idx) {
        VocabEntry *e = &ht->entries[idx - 1];
        if (strlen(e->str) == len && memcmp(e->str, str, len) == 0) {
            *out_id = e->id;
            return 1;
        }
        idx = e->next;
    }
    return 0;
}

/* ---- Merge table -------------------------------------------------------- */

typedef struct Merge {
    uint32_t left;
    uint32_t right;
    uint32_t result;
} Merge;

/* For BPE we need to find lowest-rank merge for a given pair.
 * We store merges sorted by (left, right) for binary search, keeping rank. */
typedef struct MergeIndex {
    uint32_t left;
    uint32_t right;
    uint32_t rank;    /* index in original order = priority */
    uint32_t result;
} MergeIndex;

static int merge_cmp(const void *a, const void *b) {
    const MergeIndex *ma = a, *mb = b;
    if (ma->left != mb->left) return (int)ma->left - (int)mb->left;
    return (int)ma->right - (int)mb->right;
}

static int merge_lookup(const MergeIndex *idx, uint32_t count,
                        uint32_t left, uint32_t right, uint32_t *out_rank, uint32_t *out_result) {
    int lo = 0, hi = (int)count - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        const MergeIndex *m = &idx[mid];
        if (m->left == left && m->right == right) {
            *out_rank   = m->rank;
            *out_result = m->result;
            return 1;
        }
        if (m->left < left || (m->left == left && m->right < right))
            lo = mid + 1;
        else
            hi = mid - 1;
    }
    return 0;
}

/* ---- Tokenizer struct --------------------------------------------------- */

struct KrlTok {
    VocabHT    vocab;
    char      **id_to_str;  /* reverse map: token id → string (borrowed from vocab) */
    uint32_t    vocab_size;
    MergeIndex *merges;
    uint32_t    merge_count;
};

/* ---- Load from binary files --------------------------------------------- */

static int read_u32(FILE *f, uint32_t *v) {
    return fread(v, 4, 1, f) == 1;
}
static int read_u16(FILE *f, uint16_t *v) {
    return fread(v, 2, 1, f) == 1;
}

KrlTok *krl_tok_load(const char *vocab_path, const char *merges_path) {
    init_byte_table();

    KrlTok *tok = calloc(1, sizeof(*tok));
    if (!tok) return NULL;

    /* --- vocab.bin --- */
    FILE *vf = fopen(vocab_path, "rb");
    if (!vf) { free(tok); return NULL; }

    char magic[4];
    uint32_t ver, count;
    if (fread(magic, 1, 4, vf) != 4 || memcmp(magic, VOCAB_MAGIC, 4) != 0) goto fail_v;
    if (!read_u32(vf, &ver) || ver != 1) goto fail_v;
    if (!read_u32(vf, &count)) goto fail_v;

    tok->vocab_size  = count;
    tok->vocab.count = count;
    tok->vocab.buckets = calloc(VOCAB_HT_CAP, sizeof(uint32_t));
    tok->vocab.entries = calloc(count, sizeof(VocabEntry));
    tok->vocab.strings = NULL;
    tok->id_to_str     = calloc(count, sizeof(char *));
    if (!tok->vocab.buckets || !tok->vocab.entries || !tok->id_to_str) goto fail_v;

    /* Allocate a single block for all strings (upper bound: count * 12 bytes average) */
    size_t str_cap = (size_t)count * 16;
    tok->vocab.strings = malloc(str_cap);
    if (!tok->vocab.strings) goto fail_v;
    size_t str_off = 1; /* offset 0 unused (means empty) */

    for (uint32_t i = 0; i < count; i++) {
        uint32_t id;
        uint16_t len;
        if (!read_u32(vf, &id) || !read_u16(vf, &len)) goto fail_v;
        if (id >= count) goto fail_v;

        if (str_off + len + 1 > str_cap) {
            str_cap = str_cap * 2 + len + 1;
            char *tmp = realloc(tok->vocab.strings, str_cap);
            if (!tmp) goto fail_v;
            tok->vocab.strings = tmp;
            /* Re-patch all existing str pointers — they point into the old block */
            for (uint32_t j = 0; j < i; j++)
                tok->vocab.entries[j].str = tok->vocab.strings + (tok->vocab.entries[j].str - (char*)0);
            /* Actually this pointer arithmetic is UB; use offsets instead */
        }

        /* Copy token string */
        memcpy(tok->vocab.strings + str_off, &len, 0); /* noop placeholder */
        if (fread(tok->vocab.strings + str_off, 1, len, vf) != len) goto fail_v;
        tok->vocab.strings[str_off + len] = '\0';

        VocabEntry *e = &tok->vocab.entries[i];
        e->id  = id;
        e->str = tok->vocab.strings + str_off;
        e->next = 0;
        tok->id_to_str[id] = e->str;
        str_off += len + 1;

        /* Insert into hash table */
        uint32_t h = ht_hash(e->str, len) & (VOCAB_HT_CAP - 1);
        e->next = tok->vocab.buckets[h];
        tok->vocab.buckets[h] = i + 1; /* 1-based */
    }
    fclose(vf);

    /* --- merges.bin --- */
    FILE *mf = fopen(merges_path, "rb");
    if (!mf) goto fail_cleanup;

    uint32_t mver, mcount;
    if (fread(magic, 1, 4, mf) != 4 || memcmp(magic, MERGE_MAGIC, 4) != 0) goto fail_m;
    if (!read_u32(mf, &mver) || mver != 1) goto fail_m;
    if (!read_u32(mf, &mcount)) goto fail_m;

    tok->merge_count = mcount;
    tok->merges = malloc(mcount * sizeof(MergeIndex));
    if (!tok->merges) goto fail_m;

    for (uint32_t i = 0; i < mcount; i++) {
        uint32_t l, r, res;
        if (!read_u32(mf, &l) || !read_u32(mf, &r) || !read_u32(mf, &res)) goto fail_m;
        tok->merges[i] = (MergeIndex){ .left = l, .right = r, .rank = i, .result = res };
    }
    fclose(mf);

    /* Sort by (left, right) for binary search */
    qsort(tok->merges, mcount, sizeof(MergeIndex), merge_cmp);
    return tok;

fail_m:
    fclose(mf);
fail_cleanup:
    krl_tok_free(tok);
    return NULL;
fail_v:
    fclose(vf);
    krl_tok_free(tok);
    return NULL;
}

void krl_tok_free(KrlTok *tok) {
    if (!tok) return;
    free(tok->vocab.buckets);
    free(tok->vocab.entries);
    free(tok->vocab.strings);
    free(tok->id_to_str);
    free(tok->merges);
    free(tok);
}

/* ---- BPE encoding -------------------------------------------------------- */

/* Working buffer for BPE: a sequence of token ids as a linked list.
 * We use arrays for prev/next to allow O(n) initial fill and O(1) merge. */
#define BPE_MAX_CHARS 2048

typedef struct {
    uint32_t id;
    int      next;  /* index of next element, -1 = end */
    int      prev;  /* index of prev element, -1 = start */
    int      alive; /* 0 if removed by a merge */
} BpeNode;

static BpeNode bpe_buf[BPE_MAX_CHARS];

/* Find the minimum-rank merge across all adjacent pairs in the list.
 * Returns 1 if found, 0 if no mergeable pair exists. */
static int bpe_best_merge(const KrlTok *tok, int head,
                          int *out_pos, uint32_t *out_rank, uint32_t *out_result) {
    *out_rank = UINT32_MAX;
    int found = 0;
    int i = head;
    while (i >= 0 && bpe_buf[i].next >= 0) {
        int j = bpe_buf[i].next;
        uint32_t rank, result;
        if (merge_lookup(tok->merges, tok->merge_count,
                         bpe_buf[i].id, bpe_buf[j].id, &rank, &result)) {
            if (rank < *out_rank) {
                *out_rank   = rank;
                *out_result = result;
                *out_pos    = i;
                found = 1;
            }
        }
        i = j;
    }
    return found;
}

int krl_tok_encode(const KrlTok *tok, const char *text,
                   int64_t *out_ids, int64_t *out_mask, int max_len) {
    if (!tok || !text || !out_ids || max_len < 2) return -1;

    out_ids[0] = KRL_TOK_BOS;
    if (out_mask) out_mask[0] = 1;
    int out_pos = 1;

    /* RoBERTa: prefix every word (token after whitespace) with Ġ (U+0120).
     * We process word-by-word. A "word" here is a contiguous non-whitespace run,
     * possibly with a leading space character encoded as Ġ. */
    const char *p = text;
    int first_word = 1;

    while (*p && out_pos < max_len - 1) {
        /* Collect one word */
        int is_space_prefix = !first_word || 1; /* RoBERTa always adds prefix space */
        (void)is_space_prefix;

        /* Skip whitespace (we add the Ġ prefix ourselves) */
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (!*p) break;

        /* Collect non-whitespace run */
        const char *word_start = p;
        while (*p && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') p++;
        size_t word_len = (size_t)(p - word_start);

        /* Build byte-level sequence for this word, with Ġ prefix */
        /* Each input byte → unicode codepoint → UTF-8 string → vocab id */
        int n_nodes = 0;
        int head = 0;

        /* Add Ġ (U+0120 = byte 0xC4 0xA0 in UTF-8, but in vocab it's the string "Ġ") */
        char gpref[8];
        int gpref_len = cp_to_utf8(byte_to_unicode[0x20], gpref); /* space=0x20 */
        gpref[gpref_len] = '\0';
        uint32_t gpref_id;
        if (!ht_lookup(&tok->vocab, gpref, gpref_len, &gpref_id))
            gpref_id = KRL_TOK_UNK;
        bpe_buf[n_nodes] = (BpeNode){ .id = gpref_id, .next = n_nodes + 1, .prev = -1, .alive = 1 };
        n_nodes++;

        /* Add each byte of the word */
        for (size_t bi = 0; bi < word_len && n_nodes < BPE_MAX_CHARS - 1; bi++) {
            uint32_t cp = byte_to_unicode[(unsigned char)word_start[bi]];
            char bs[8];
            int bs_len = cp_to_utf8(cp, bs);
            bs[bs_len] = '\0';
            uint32_t bid;
            if (!ht_lookup(&tok->vocab, bs, bs_len, &bid))
                bid = KRL_TOK_UNK;
            bpe_buf[n_nodes] = (BpeNode){
                .id = bid, .next = n_nodes + 1, .prev = n_nodes - 1, .alive = 1
            };
            n_nodes++;
        }
        if (n_nodes > 0) {
            bpe_buf[n_nodes - 1].next = -1;
        }

        /* Apply BPE merges */
        int pos;
        uint32_t rank, result;
        while (bpe_best_merge(tok, head, &pos, &rank, &result)) {
            int j = bpe_buf[pos].next;
            bpe_buf[pos].id    = result;
            bpe_buf[pos].next  = bpe_buf[j].next;
            if (bpe_buf[j].next >= 0)
                bpe_buf[bpe_buf[j].next].prev = pos;
            bpe_buf[j].alive = 0;
        }

        /* Collect output tokens */
        int cur = head;
        while (cur >= 0) {
            if (bpe_buf[cur].alive && out_pos < max_len - 1) {
                out_ids[out_pos] = (int64_t)bpe_buf[cur].id;
                if (out_mask) out_mask[out_pos] = 1;
                out_pos++;
            }
            cur = bpe_buf[cur].next;
        }

        first_word = 0;
    }

    /* EOS */
    out_ids[out_pos] = (int64_t)KRL_TOK_EOS;
    if (out_mask) out_mask[out_pos] = 1;
    out_pos++;

    return out_pos;
}

/* ---- Decode ---------------------------------------------------------------- */

/* UTF-8 bytes of U+0120 (Ġ), the GPT-2 space marker prepended to words. */
#define SPACE_MARKER_B0 ((unsigned char)0xC4)
#define SPACE_MARKER_B1 ((unsigned char)0xA0)

int krl_tok_decode(const KrlTok *tok,
                   const int64_t *ids,
                   int            n_ids,
                   char          *out,
                   int            out_size) {
    if (!tok || !ids || !out || out_size < 1) return -1;
    int written = 0;
    for (int i = 0; i < n_ids; i++) {
        int64_t id = ids[i];
        if (id <= 0 || (uint64_t)id >= tok->vocab_size) continue;
        if (id == KRL_TOK_BOS || id == KRL_TOK_EOS || id == KRL_TOK_PAD) continue;
        const char *s = tok->id_to_str[id];
        if (!s) continue;
        /* Strip leading Ġ space-marker */
        if ((unsigned char)s[0] == SPACE_MARKER_B0 &&
            (unsigned char)s[1] == SPACE_MARKER_B1) {
            s += 2;
        }
        int slen = (int)strlen(s);
        if (written + slen >= out_size - 1) break;
        memcpy(out + written, s, (size_t)slen);
        written += slen;
    }
    out[written] = '\0';
    return written;
}
