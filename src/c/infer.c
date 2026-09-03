#include "infer.h"
#include <onnxruntime_c_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* ---- ORT setup ---------------------------------------------------------- */

static const OrtApi *g_ort = NULL;

/* Called once. Returns 0 on success. */
static int ort_init(void) {
    if (g_ort) return 0;
    const OrtApiBase *base = OrtGetApiBase();
    g_ort = base->GetApi(ORT_API_VERSION);
    return g_ort ? 0 : -1;
}

#define ORT_CHECK(expr)                                                   \
    do {                                                                  \
        OrtStatus *_s = (expr);                                           \
        if (_s) {                                                         \
            fprintf(stderr, "[krul] ORT error: %s\n",                 \
                    g_ort->GetErrorMessage(_s));                          \
            g_ort->ReleaseStatus(_s);                                     \
            return -1;                                                    \
        }                                                                 \
    } while (0)

#define ORT_CHECK_NULL(expr, label)                                       \
    do {                                                                  \
        OrtStatus *_s = (expr);                                           \
        if (_s) {                                                         \
            fprintf(stderr, "[krul] ORT error: %s\n",                 \
                    g_ort->GetErrorMessage(_s));                          \
            g_ort->ReleaseStatus(_s);                                     \
            goto label;                                                   \
        }                                                                 \
    } while (0)

/* ---- Runtime struct ----------------------------------------------------- */

struct KrlRuntime {
    OrtEnv            *env;
    OrtSessionOptions *opts;
    OrtSession        *ner_session;
    OrtSession        *enc_session;
    OrtMemoryInfo     *mem_info;
};

/* ---- Load --------------------------------------------------------------- */

KrlRuntime *krl_runtime_load(const char *ner_path, const char *encoder_path) {
    if (ort_init() != 0) return NULL;

    KrlRuntime *rt = calloc(1, sizeof(*rt));
    if (!rt) return NULL;

    OrtStatus *s;

    s = g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "krul", &rt->env);
    if (s) { g_ort->ReleaseStatus(s); free(rt); return NULL; }

    s = g_ort->CreateSessionOptions(&rt->opts);
    if (s) { g_ort->ReleaseStatus(s); goto fail; }

    /* CPU only; single thread per session (daemon manages parallelism above) */
    g_ort->SetIntraOpNumThreads(rt->opts, 1);
    g_ort->SetInterOpNumThreads(rt->opts, 1);
    g_ort->SetSessionGraphOptimizationLevel(rt->opts, ORT_ENABLE_ALL);

    s = g_ort->CreateSession(rt->env, ner_path, rt->opts, &rt->ner_session);
    if (s) { g_ort->ReleaseStatus(s); goto fail; }

    s = g_ort->CreateSession(rt->env, encoder_path, rt->opts, &rt->enc_session);
    if (s) { g_ort->ReleaseStatus(s); goto fail; }

    s = g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &rt->mem_info);
    if (s) { g_ort->ReleaseStatus(s); goto fail; }

    return rt;

fail:
    krl_runtime_free(rt);
    return NULL;
}

void krl_runtime_free(KrlRuntime *rt) {
    if (!rt) return;
    if (rt->mem_info)    g_ort->ReleaseMemoryInfo(rt->mem_info);
    if (rt->ner_session) g_ort->ReleaseSession(rt->ner_session);
    if (rt->enc_session) g_ort->ReleaseSession(rt->enc_session);
    if (rt->opts)        g_ort->ReleaseSessionOptions(rt->opts);
    if (rt->env)         g_ort->ReleaseEnv(rt->env);
    free(rt);
}

/* ---- Tensor helpers ------------------------------------------------------ */

static OrtValue *make_int64_tensor(KrlRuntime *rt,
                                   const int64_t *data, int64_t batch, int64_t seq) {
    int64_t shape[2] = { batch, seq };
    OrtValue *tensor = NULL;
    OrtStatus *s = g_ort->CreateTensorWithDataAsOrtValue(
        rt->mem_info,
        (void *)data, (size_t)(batch * seq) * sizeof(int64_t),
        shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,
        &tensor);
    if (s) { g_ort->ReleaseStatus(s); return NULL; }
    return tensor;
}

/* ---- NER run ------------------------------------------------------------ */

int krl_ner_run(KrlRuntime *rt, const int64_t *input_ids, const int64_t *attention_mask,
                int seq_len, KrlNerResult *out) {
    if (!rt || !rt->ner_session || !out) return -1;

    int64_t batch = 1;
    OrtValue *in_ids  = make_int64_tensor(rt, input_ids,      batch, seq_len);
    OrtValue *in_mask = make_int64_tensor(rt, attention_mask, batch, seq_len);
    if (!in_ids || !in_mask) {
        if (in_ids)  g_ort->ReleaseValue(in_ids);
        if (in_mask) g_ort->ReleaseValue(in_mask);
        return -1;
    }

    const char *in_names[]  = { "input_ids", "attention_mask" };
    const char *out_names[] = { "logits" };
    OrtValue   *inputs[]    = { in_ids, in_mask };
    OrtValue   *outputs[]   = { NULL };

    OrtStatus *s = g_ort->Run(rt->ner_session, NULL,
                               in_names, (const OrtValue *const *)inputs, 2,
                               out_names, 1, outputs);
    g_ort->ReleaseValue(in_ids);
    g_ort->ReleaseValue(in_mask);
    if (s) { g_ort->ReleaseStatus(s); return -1; }

    /* logits shape: [1, seq_len, num_labels] */
    OrtTensorTypeAndShapeInfo *info = NULL;
    g_ort->GetTensorTypeAndShape(outputs[0], &info);
    size_t ndim;
    g_ort->GetDimensionsCount(info, &ndim);
    int64_t dims[4] = {0};
    g_ort->GetDimensions(info, dims, ndim < 4 ? ndim : 4);
    g_ort->ReleaseTensorTypeAndShapeInfo(info);

    int64_t num_labels = (ndim >= 3) ? dims[2] : 1;
    float *logits_data = NULL;
    g_ort->GetTensorMutableData(outputs[0], (void **)&logits_data);

    out->seq_len = seq_len;
    out->labels  = malloc(seq_len * sizeof(int32_t));
    out->scores  = malloc(seq_len * sizeof(float));
    if (!out->labels || !out->scores) {
        free(out->labels); free(out->scores);
        g_ort->ReleaseValue(outputs[0]);
        return -1;
    }

    /* Argmax per position */
    for (int t = 0; t < seq_len; t++) {
        float *row = logits_data + t * num_labels;
        int    best_id = 0;
        float  best_v  = row[0];
        for (int k = 1; k < num_labels; k++) {
            if (row[k] > best_v) { best_v = row[k]; best_id = k; }
        }
        /* Softmax for confidence — numerically stable */
        float sum = 0.0f;
        for (int k = 0; k < num_labels; k++) sum += expf(row[k] - best_v);
        out->labels[t] = best_id;
        out->scores[t] = 1.0f / sum;
    }

    g_ort->ReleaseValue(outputs[0]);
    return 0;
}

void krl_ner_result_free(KrlNerResult *r) {
    if (!r) return;
    free(r->labels);
    free(r->scores);
    r->labels = NULL;
    r->scores = NULL;
    r->seq_len = 0;
}

/* ---- Encoder run -------------------------------------------------------- */

int krl_encode_run(KrlRuntime *rt, const int64_t *input_ids, const int64_t *attention_mask,
                   int seq_len, KrlEmbed *out) {
    if (!rt || !rt->enc_session || !out) return -1;

    int64_t batch = 1;
    OrtValue *in_ids  = make_int64_tensor(rt, input_ids,      batch, seq_len);
    OrtValue *in_mask = make_int64_tensor(rt, attention_mask, batch, seq_len);
    if (!in_ids || !in_mask) {
        if (in_ids)  g_ort->ReleaseValue(in_ids);
        if (in_mask) g_ort->ReleaseValue(in_mask);
        return -1;
    }

    const char *in_names[]  = { "input_ids", "attention_mask" };
    /* Use the pooled "tanh" output (shape [1, 768]) — the CLS-based sequence embedding */
    const char *out_names[] = { "tanh" };
    OrtValue   *inputs[]    = { in_ids, in_mask };
    OrtValue   *outputs[]   = { NULL };

    OrtStatus *s = g_ort->Run(rt->enc_session, NULL,
                               in_names, (const OrtValue *const *)inputs, 2,
                               out_names, 1, outputs);
    g_ort->ReleaseValue(in_ids);
    g_ort->ReleaseValue(in_mask);
    if (s) { g_ort->ReleaseStatus(s); return -1; }

    float *pooled = NULL;
    g_ort->GetTensorMutableData(outputs[0], (void **)&pooled);
    memcpy(out->embed, pooled, KRL_EMBED_DIM * sizeof(float));

    g_ort->ReleaseValue(outputs[0]);
    return 0;
}
