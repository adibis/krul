#!/usr/bin/env python3
"""
Convert a HuggingFace tokenizer.json (RoBERTa BPE) into the binary format
expected by krul's C tokenizer (tok.c).

Produces:
  vocab.bin   — vocabulary entries with token strings
  merges.bin  — BPE merge rules as (left_id, right_id, result_id) triples

Usage:
  python tools/convert_tokenizer.py \
      --tokenizer path/to/tokenizer.json \
      --out-dir   path/to/output/dir
"""

import argparse
import json
import struct
from pathlib import Path


VOCAB_MAGIC = b"ICRV"
MERGE_MAGIC = b"ICRM"


def load_tokenizer(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def build_vocab_bin(vocab: dict[str, int], out_path: Path) -> None:
    """Write vocab.bin. Entries are sorted by token id."""
    entries = sorted(vocab.items(), key=lambda kv: kv[1])
    count = len(entries)

    with open(out_path, "wb") as f:
        f.write(VOCAB_MAGIC)
        f.write(struct.pack("<I", 1))       # version
        f.write(struct.pack("<I", count))   # entry count

        for token_str, token_id in entries:
            token_bytes = token_str.encode("utf-8")
            length = len(token_bytes)
            if length > 65535:
                raise ValueError(f"Token too long: {token_str!r}")
            f.write(struct.pack("<I", token_id))
            f.write(struct.pack("<H", length))
            f.write(token_bytes)

    print(f"  vocab.bin: {count} entries → {out_path}")


def build_merges_bin(merges: list[list[str]], vocab: dict[str, int], out_path: Path) -> None:
    """Write merges.bin. Merges are stored in priority order (rank 0 = apply first).
    Each merge entry stores (left_id, right_id, result_id)."""
    count = len(merges)

    skipped = 0
    with open(out_path, "wb") as f:
        # Write header with placeholder count; we'll fix it up if we skip any
        header_pos = f.tell()
        f.write(MERGE_MAGIC)
        f.write(struct.pack("<I", 1))       # version
        f.write(struct.pack("<I", count))   # entry count (may be adjusted)

        written = 0
        for left_str, right_str in merges:
            merged_str = left_str + right_str
            left_id   = vocab.get(left_str)
            right_id  = vocab.get(right_str)
            result_id = vocab.get(merged_str)
            if left_id is None or right_id is None or result_id is None:
                skipped += 1
                continue
            f.write(struct.pack("<I", left_id))
            f.write(struct.pack("<I", right_id))
            f.write(struct.pack("<I", result_id))
            written += 1

        if skipped:
            # Fix up count
            f.seek(header_pos + 8)
            f.write(struct.pack("<I", written))

    print(f"  merges.bin: {written} entries ({skipped} skipped) → {out_path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tokenizer", required=True, help="Path to tokenizer.json")
    ap.add_argument("--out-dir",   required=True, help="Output directory for vocab.bin and merges.bin")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading {args.tokenizer} ...")
    data = load_tokenizer(args.tokenizer)

    model = data["model"]
    if model["type"] != "BPE":
        raise ValueError(f"Expected BPE tokenizer, got: {model['type']}")

    vocab  = model["vocab"]   # dict: str → int
    merges = model["merges"]  # list of [str, str]

    print(f"  vocab size: {len(vocab)}")
    print(f"  merge count: {len(merges)}")
    print()

    build_vocab_bin(vocab, out_dir / "vocab.bin")
    build_merges_bin(merges, vocab, out_dir / "merges.bin")

    print("\nDone. Copy vocab.bin and merges.bin to your krul models/ directory.")


if __name__ == "__main__":
    main()
