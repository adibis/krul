#!/usr/bin/env python3
"""
Experiment III benchmark — v2 held-out cohort.

All 4 files are from OpenTitan, which is fully excluded from the 13-repo
NER training corpus. 20 questions across 5 categories.

Runs both context conditions for each question:
  1. Raw SV  : full file content
  2. NER rec : compact structured record from extractor.py

Scores against gold answers and prints per-condition accuracy.
"""

import sys, json, re, textwrap, requests
from pathlib import Path
from collections import defaultdict

sys.path.insert(0, str(Path(__file__).parent))
from extractor import extract_dir

OLLAMA_URL = "http://localhost:11434/api/generate"
MODEL      = "qwen2.5-coder:7b"

# ── File paths ────────────────────────────────────────────────────────────────
OT = "/Users/aditya/azath-model/corpus/opentitan"
FILES = {
    "entropy_src_env":    f"{OT}/hw/ip/entropy_src/dv/env/entropy_src_env.sv",
    "otbn_env":           f"{OT}/hw/ip/otbn/dv/uvm/env/otbn_env.sv",
    "csrng_env_cfg":      f"{OT}/hw/ip/csrng/dv/env/csrng_env_cfg.sv",
    "aes_env_cfg":        f"{OT}/hw/ip/aes/dv/env/aes_env_cfg.sv",
}

# ── 20 benchmark questions with gold answers ──────────────────────────────────
# category: E=entity-declaration (NER target), I=implementation-logic (raw SV target)
QUESTIONS = [
    # --- entropy_src_env.sv ---
    dict(file="entropy_src_env", cat="E",
         q="What class does `entropy_src_env` extend?",
         gold="cip_base_env"),
    dict(file="entropy_src_env", cat="E",
         q="List all agent field declarations in `entropy_src_env`.",
         gold="m_rng_agent (push_pull_agent), m_csrng_agent (push_pull_agent), m_xht_agent (entropy_src_xht_agent)"),
    dict(file="entropy_src_env", cat="E",
         q="Which UVM phase methods does `entropy_src_env` override?",
         gold="build_phase, connect_phase"),
    dict(file="entropy_src_env", cat="I",
         q="What condition in `entropy_src_env.build_phase` triggers reduction of `d_ready_delay_max`?",
         gold="cfg.rng_max_delay == 1"),
    dict(file="entropy_src_env", cat="I",
         q="What sequencer handles does `entropy_src_env.connect_phase` wire up to the virtual sequencer?",
         gold="csrng_sequencer_h, rng_sequencer_h, xht_sequencer"),

    # --- otbn_env.sv ---
    dict(file="otbn_env", cat="E",
         q="What class does `otbn_env` extend?",
         gold="cip_base_env"),
    dict(file="otbn_env", cat="E",
         q="List all agent and monitor field declarations in `otbn_env`.",
         gold="model_agent (otbn_model_agent), trace_monitor (otbn_trace_monitor), keymgr_sideload_agent (otbn_sideload_agent), key_agent (otp_key_agent)"),
    dict(file="otbn_env", cat="E",
         q="Which UVM phase methods does `otbn_env` override?",
         gold="build_phase, connect_phase, final_phase"),
    dict(file="otbn_env", cat="I",
         q="What virtual interface type does `otbn_env.build_phase` retrieve into `cfg.trace_vif`?",
         gold="virtual otbn_trace_if"),
    dict(file="otbn_env", cat="I",
         q="What does `otbn_env.final_phase` do to `cfg.mem_util`?",
         gold="Calls OtbnMemUtilFree and sets cfg.mem_util to null"),

    # --- csrng_env_cfg.sv ---
    dict(file="csrng_env_cfg", cat="E",
         q="What class does `csrng_env_cfg` extend?",
         gold="cip_base_env_cfg with RAL_T=csrng_reg_block"),
    dict(file="csrng_env_cfg", cat="E",
         q="List the virtual interface handles declared in `csrng_env_cfg`.",
         gold="otp_en_cs_sw_app_read_vif, lc_hw_debug_en_vif, csrng_assert_vif, csrng_path_vif, csrng_agents_vif"),
    dict(file="csrng_env_cfg", cat="E",
         q="What rand agent configuration fields does `csrng_env_cfg` declare?",
         gold="m_entropy_src_agent_cfg (push_pull_agent_cfg), m_edn_agent_cfg (csrng_agent_cfg array)"),
    dict(file="csrng_env_cfg", cat="E",
         q="What is the RAL type parameter for `csrng_env_cfg`?",
         gold="csrng_reg_block"),
    dict(file="csrng_env_cfg", cat="I",
         q="What range does the `reseed_interval_c` constraint impose on `reseed_interval`?",
         gold="1 to 10 (inside {[1:10]})"),

    # --- aes_env_cfg.sv ---
    dict(file="aes_env_cfg", cat="E",
         q="What class does `aes_env_cfg` extend?",
         gold="cip_base_env_cfg with RAL_T=aes_reg_block"),
    dict(file="aes_env_cfg", cat="E",
         q="List the first three virtual interface handles declared in `aes_env_cfg`.",
         gold="lc_escalate_vif (pins_if), idle_vif (pins_if), aes_reseed_vif (aes_reseed_if)"),
    dict(file="aes_env_cfg", cat="E",
         q="What rand field does `aes_env_cfg` declare for key management sideloading?",
         gold="keymgr_sideload_agent_cfg (key_sideload_agent_cfg)"),
    dict(file="aes_env_cfg", cat="I",
         q="What is the default value of `num_messages_min` in `aes_env_cfg`?",
         gold="1"),
    dict(file="aes_env_cfg", cat="I",
         q="What AES modes are defined by weight fields in `aes_env_cfg`, and what are their default weights?",
         gold="ecb, cbc, ofb, cfb, ctr, gcm — all default to weight 10"),
]

# ── Build NER records from extractor.py output ────────────────────────────────
def build_ner_record(file_key: str, sv_path: str) -> str:
    """Run extractor on the file's parent dir, collect triples for this file."""
    parent = str(Path(sv_path).parent)
    try:
        triples, _ = extract_dir(parent)
    except Exception as e:
        return f"[extractor error: {e}]"

    ents   = [t for t in triples if t.get('type') == 'entity'   and t['file'] == sv_path]
    rels   = [t for t in triples if t.get('type') == 'relation' and t.get('file') == sv_path]

    if not ents:
        return "[no entities found]"

    lines = []
    for ent in ents:
        lines.append(f"ENTITY: {ent['name']}  TYPE: {ent.get('kind','?')}")
        for r in rels:
            if r.get('subject') == ent['name']:
                obj  = r.get('object','?')
                rtype = r.get('relation','?')
                extra = r.get('object_type','')
                if extra:
                    lines.append(f"  {rtype}: {obj} ({extra})")
                else:
                    lines.append(f"  {rtype}: {obj}")
        lines.append("")
    return "\n".join(lines).strip()


# ── Ollama query ──────────────────────────────────────────────────────────────
SYSTEM = (
    "You are a SystemVerilog and UVM expert. "
    "Answer the question concisely based only on the provided context. "
    "Give the exact names/values from the source — do not paraphrase or guess."
)

def query(context: str, question: str) -> str:
    prompt = f"{SYSTEM}\n\nContext:\n{context}\n\nQuestion: {question}\n\nAnswer:"
    try:
        r = requests.post(OLLAMA_URL, json={
            "model": MODEL,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": 0, "num_predict": 200},
        }, timeout=120)
        return r.json().get("response", "").strip()
    except Exception as e:
        return f"[error: {e}]"


# ── Scoring (manual — print for human review) ─────────────────────────────────
def main():
    # Load file contents
    contents = {k: Path(v).read_text(errors='replace') for k, v in FILES.items()}

    # Build NER records once per file
    print("Building NER records ...", flush=True)
    records = {}
    for k, path in FILES.items():
        rec = build_ner_record(k, path)
        records[k] = rec
        lines = rec.count('\n') + 1
        print(f"  {k}: {lines} lines", flush=True)

    print(f"\nRunning {len(QUESTIONS)} questions × 2 conditions ...\n", flush=True)

    results = []
    for i, q in enumerate(QUESTIONS, 1):
        fkey = q['file']
        raw_sv   = contents[fkey]
        ner_rec  = records[fkey]

        ans_raw = query(raw_sv,  q['q'])
        ans_ner = query(ner_rec, q['q'])

        results.append(dict(
            n=i, file=fkey, cat=q['cat'],
            question=q['q'], gold=q['gold'],
            ans_raw=ans_raw, ans_ner=ans_ner,
        ))

        print(f"Q{i:02d} [{q['cat']}] {fkey}", flush=True)
        print(f"  Q: {q['q']}", flush=True)
        print(f"  Gold: {q['gold']}", flush=True)
        print(f"  Raw SV : {ans_raw[:120]}", flush=True)
        print(f"  NER rec: {ans_ner[:120]}", flush=True)
        print(flush=True)

    # Save results for scoring
    out = "/tmp/benchmark_v2_results.json"
    with open(out, 'w') as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to {out}", flush=True)
    print("Score each answer against gold above and update the paper.", flush=True)

    # Token counts
    import subprocess
    print("\n=== Token counts (Qwen tokenizer approx via char/4) ===", flush=True)
    for k, path in FILES.items():
        txt = contents[k]
        rec = records[k]
        print(f"  {k}: raw={len(txt)//4} tok  NER={len(rec)//4} tok  "
              f"ratio={len(txt)/max(len(rec),1):.1f}x", flush=True)


if __name__ == '__main__':
    main()
