#!/usr/bin/env python3
"""
Cross-repository NER evaluation on OpenTitan hw/dv/sv + hw/ip/uart/dv.
These directories are fully held out from the 13-repo NER training corpus.
Generates IOB2 labels via the same extractor/tokenizer pipeline as training,
runs the saved checkpoint, and reports per-kind seqeval F1.
"""
import sys, re, numpy as np, torch
from pathlib import Path
from collections import defaultdict
from transformers import AutoTokenizer, AutoModelForTokenClassification
from seqeval.metrics import classification_report

sys.path.insert(0, str(Path(__file__).parent))
from extractor import extract_dir
from generate_ner_data import make_chunks, find_span

MODEL_DIR = '/Users/aditya/azath-model/ner_v2'
OT_DIRS   = [
    '/Users/aditya/azath-model/corpus/opentitan/hw/dv/sv',
    '/Users/aditya/azath-model/corpus/opentitan/hw/ip/uart/dv',
]
BATCH = 16


def main():
    print("Loading model ...", flush=True)
    tokenizer = AutoTokenizer.from_pretrained(MODEL_DIR)
    model     = AutoModelForTokenClassification.from_pretrained(MODEL_DIR)
    id2l      = model.config.id2label
    model.eval()

    device = (torch.device('mps')  if torch.backends.mps.is_available() else
              torch.device('cuda') if torch.cuda.is_available() else
              torch.device('cpu'))
    model = model.to(device)
    print(f"Device: {device}", flush=True)

    records = []
    for root in OT_DIRS:
        print(f"\nExtracting {root} ...", flush=True)
        try:
            ents_raw, _ = extract_dir(root)
        except Exception as e:
            print(f"  error: {e}", flush=True)
            continue

        file_ents = defaultdict(list)
        all_files = set()
        for ent in ents_raw:
            if ent.get('type') != 'entity':
                continue
            file_ents[ent['file']].append(
                (ent['name'], ent['kind'], ent['line_start'])
            )
        for ext in ('*.sv', '*.svh'):
            for f in Path(root).rglob(ext):
                all_files.add(str(f))

        print(f"  {len(file_ents)} labeled / {len(all_files)} total files", flush=True)

        for fpath in sorted(all_files):
            try:
                text = Path(fpath).read_text(errors='replace')
            except Exception:
                continue
            if not text.strip():
                continue
            spans = []
            for (name, kind, line_start) in file_ents.get(fpath, []):
                s = find_span(text, name, line_start)
                if s:
                    spans.append((s[0], s[1], kind))
            try:
                chunks = make_chunks(text, spans, tokenizer)
                records.extend(chunks)
            except Exception:
                continue

    print(f"\nTotal eval chunks: {len(records)}", flush=True)
    if not records:
        print("No records — check paths", flush=True)
        return

    inp  = np.array([r['input_ids']      for r in records], dtype=np.int64)
    attn = np.array([r['attention_mask'] for r in records], dtype=np.int64)
    labs = np.array([r['labels']         for r in records], dtype=np.int64)

    all_p, all_g = [], []
    with torch.no_grad():
        for i in range(0, len(inp), BATCH):
            b_inp = torch.from_numpy(inp[i:i+BATCH].copy()).to(device)
            b_att = torch.from_numpy(attn[i:i+BATCH].copy()).to(device)
            b_lab = torch.from_numpy(labs[i:i+BATCH].copy())
            logits = model(input_ids=b_inp, attention_mask=b_att).logits
            preds  = logits.argmax(-1).cpu().tolist()
            golds  = b_lab.tolist()
            for ps, gs in zip(preds, golds):
                pr, gr = [], []
                for p, g in zip(ps, gs):
                    if g == -100: continue
                    pr.append(id2l[p]); gr.append(id2l[g])
                all_p.append(pr); all_g.append(gr)

    print("\n=== Cross-Repo NER F1 (OpenTitan hw/dv + uart — held-out from training) ===\n",
          flush=True)
    print(classification_report(all_g, all_p, digits=4), flush=True)


if __name__ == '__main__':
    main()
