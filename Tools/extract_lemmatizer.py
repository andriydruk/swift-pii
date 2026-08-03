#!/usr/bin/env python3
"""Extract the model's rule-mode lemmatizer tables.

`lemma_rules`, `lemma_exc` and `lemma_index`, keyed by coarse POS. In the model
they are keyed by string-store hash, so this resolves the names back.

`lemma_index` is a membership set, not a mapping: `rule_lemmatize` uses it to
decide whether a candidate form is a real word, which is what stops "ies" -> "y"
from producing nonsense.

Usage:
    python3 Tools/extract_lemmatizer.py --python <venv python> --model <dir> \\
        --out Sources/PresidioNLP/Resources/en_lemmatizer.json
"""

from __future__ import annotations

import argparse, json, os, subprocess, sys

CHILD = r'''
import json, sys, srsly
from spacy.strings import get_string_id

model = sys.argv[1]
raw = srsly.msgpack_loads(open(model + "/lemmatizer/lookups/lookups.bin", "rb").read())

# The tables are hash-keyed; resolve the coarse POS names back.
NAMES = ["adj", "adv", "noun", "verb", "punct", "propn", "aux", "det", "pron",
         "num", "part", "sconj", "cconj", "adp", "intj", "sym", "x"]
by_hash = {get_string_id(n): n for n in NAMES}

def named(table):
    out = {}
    for key, value in table.items():
        name = by_hash.get(key)
        if name is not None:
            out[name] = value
    return out

rules = named(raw.get("lemma_rules", {}))
exc = named(raw.get("lemma_exc", {}))
index = named(raw.get("lemma_index", {}))

json.dump({
    "rules": {k: [list(pair) for pair in v] for k, v in rules.items()},
    "exceptions": {k: {kk: list(vv) for kk, vv in v.items()} for k, v in exc.items()},
    "index": {k: sorted(v) for k, v in index.items()},
}, sys.stdout, ensure_ascii=False)
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proc = subprocess.run([args.python, "-c", CHILD, args.model],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stderr[-3000:], file=sys.stderr)
        return 2

    payload = json.loads(proc.stdout)
    payload["schema_version"] = 1
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")

    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    for name in ("rules", "exceptions", "index"):
        sizes = {k: len(v) for k, v in payload[name].items()}
        print(f"  {name}: {sizes}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
