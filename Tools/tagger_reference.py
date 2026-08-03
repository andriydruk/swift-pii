#!/usr/bin/env python3
"""Record spaCy's tags, POS and lemmas as a differential oracle.

Covers the whole chain the port has to reproduce: fine-grained tag from the
tagger, coarse POS from the attribute ruler, and the rule-mode lemma that keys
off it. Recording all three means a divergence can be attributed to a stage
rather than just observed at the end.

Usage:
    python3 Tools/tagger_reference.py --python <venv python> --model <dir> \\
        --texts <json array> --out Tests/PresidioConformance/Fixtures/tagger_gold.json
"""

from __future__ import annotations

import argparse, json, os, subprocess, sys

CHILD = r'''
import json, sys
import spacy

model, texts_path = sys.argv[1], sys.argv[2]
nlp = spacy.load(model)
texts = json.load(open(texts_path))

out = []
for text in texts:
    doc = nlp(text)
    out.append({
        "text": text,
        "tokens": [
            {"text": t.text, "offset": t.idx, "norm": t.norm_,
             "tag": t.tag_, "pos": t.pos_, "lemma": t.lemma_}
            for t in doc
        ],
    })
json.dump({"model": nlp.meta["name"] + "-" + nlp.meta["version"],
           "spacy_version": spacy.__version__, "texts": out},
          sys.stdout, ensure_ascii=False)
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--texts", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proc = subprocess.run([args.python, "-c", CHILD, args.model, args.texts],
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

    tokens = sum(len(t["tokens"]) for t in payload["texts"])
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  {len(payload['texts'])} texts, {tokens} tokens, {payload['model']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
