#!/usr/bin/env python3
"""
Generate IOB2 NER training data from SV/UVM repositories.

Runs extract_dir() on each repo, groups entities by file, tokenizes with
GraphCodeBERT (512-token sliding window, stride=256), and aligns entity
name spans to B-KIND/I-KIND/O labels via offset mapping.

Output: /tmp/ner_data_v2.jsonl
"""

import re, sys, json
from pathlib import Path
from collections import defaultdict

sys.path.insert(0, str(Path(__file__).parent))
from extractor import extract_dir, PARTITION

from transformers import AutoTokenizer

TOKENIZER_NAME = "microsoft/graphcodebert-base"
MAX_LEN   = 512
STRIDE    = 256
OUT_PATH  = "/tmp/ner_data_v2.jsonl"

REPOS = [
    '/tmp/sv_bench_repos/core-v-mcu-uvm',
    '/tmp/sv_bench_repos/riscv-dv',
    '/tmp/sv_bench_repos/riscv-core-dv-uvm',
    '/tmp/sv_bench_repos/ofm',
    '/tmp/sv_bench_repos/cv-hpdcache-verif',
    '/tmp/sv_bench_repos/uvm-components',
    '/tmp/sv_bench_repos/uvm_agents',
    '/tmp/sv_bench_repos/riscv-vip',
    '/tmp/sv_bench_repos/Async_FIFO_Verification',
    '/tmp/sv_bench_repos/cvfpu-uvm',
    '/tmp/sv_bench_repos/cheriot-ibex-dv',
    '/tmp/sv_bench_repos/black-parrot',
    '/tmp/sv_bench_repos/snitch_cluster',
    '/tmp/sv_bench_repos/sonata-system',
]

KINDS      = sorted(PARTITION.keys())
LABEL_LIST = ['O'] + [f'B-{k}' for k in KINDS] + [f'I-{k}' for k in KINDS]
LABEL2ID   = {l: i for i, l in enumerate(LABEL_LIST)}


def find_span(text, name, line_start):
    """Return (char_start, char_end) of `name` on the declaration line, or None."""
    lines = text.splitlines(keepends=True)
    if line_start < 1 or line_start > len(lines):
        return None
    offset = sum(len(l) for l in lines[:line_start - 1])
    # Search on the declaration line plus next 3 lines for multi-line declarations
    window = ''.join(lines[line_start - 1: min(line_start + 3, len(lines))])
    m = re.search(r'\b' + re.escape(name) + r'\b', window)
    if m:
        return (offset + m.start(), offset + m.end())
    return None


def make_chunks(text, spans, tokenizer):
    """Tokenize with sliding window; assign IOB2 labels from entity spans."""
    enc = tokenizer(
        text,
        max_length=MAX_LEN,
        stride=STRIDE,
        return_overflowing_tokens=True,
        return_offsets_mapping=True,
        truncation=True,
        padding='max_length',
    )
    chunks = []
    for inp_ids, attn, offsets in zip(
        enc['input_ids'], enc['attention_mask'], enc['offset_mapping']
    ):
        labels = []
        for tok_s, tok_e in offsets:
            if tok_s == tok_e:          # special token ([CLS], [SEP], padding)
                labels.append(-100)
                continue
            lbl = 'O'
            for (ent_s, ent_e, kind) in spans:
                if tok_s >= ent_s and tok_e <= ent_e:
                    lbl = f'B-{kind}' if tok_s == ent_s else f'I-{kind}'
                    break
            labels.append(LABEL2ID[lbl])
        chunks.append({
            'input_ids':      inp_ids,
            'attention_mask': attn,
            'labels':         labels,
        })
    return chunks


def main():
    print(f"Loading tokenizer {TOKENIZER_NAME} ...")
    tokenizer = AutoTokenizer.from_pretrained(TOKENIZER_NAME)

    # ── Collect entities per file from all repos ──────────────────────────────
    file_entities = defaultdict(list)   # filepath -> [(name, kind, line_start)]
    all_files: set[str] = set()

    for repo in REPOS:
        p = Path(repo)
        if not p.exists():
            print(f"  [skip] {repo}")
            continue
        print(f"  Extracting {repo} ...")
        try:
            ents, _ = extract_dir(repo)
        except Exception as e:
            print(f"  [error] {repo}: {e}")
            continue
        for ent in ents:
            if ent.get('type') != 'entity':
                continue
            file_entities[ent['file']].append(
                (ent['name'], ent['kind'], ent['line_start'])
            )
        for ext in ('*.sv', '*.svh'):
            for f in p.rglob(ext):
                all_files.add(str(f))

    labeled_files = len(file_entities)
    print(f"Files with ≥1 entity: {labeled_files} / {len(all_files)} total")

    # ── Tokenize and label ────────────────────────────────────────────────────
    total_chunks = 0
    skipped = 0
    with open(OUT_PATH, 'w') as out:
        for fpath in sorted(all_files):
            try:
                text = Path(fpath).read_text(errors='replace')
            except Exception:
                skipped += 1
                continue
            if not text.strip():
                skipped += 1
                continue

            ents = file_entities.get(fpath, [])
            spans = []
            for (name, kind, line_start) in ents:
                s = find_span(text, name, line_start)
                if s:
                    spans.append((s[0], s[1], kind))

            try:
                chunks = make_chunks(text, spans, tokenizer)
            except Exception as e:
                print(f"  [warn] tokenize error {fpath}: {e}")
                skipped += 1
                continue

            for chunk in chunks:
                out.write(json.dumps(chunk) + '\n')
            total_chunks += len(chunks)

    print(f"Wrote {total_chunks} chunks to {OUT_PATH}  (skipped {skipped} files)")
    print(f"Label set ({len(LABEL_LIST)}): {LABEL_LIST[:7]} ...")


if __name__ == '__main__':
    main()
