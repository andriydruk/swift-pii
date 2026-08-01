#!/usr/bin/env python3
"""Record Presidio's AnalyzerEngine behaviour as a differential oracle.

Two things are captured per text, and the split matters:

1. The **NLP artifacts** spaCy produced -- tokens, offsets, lemmas, keywords,
   NER entities. The Swift side is fed these verbatim rather than running its
   own pipeline, so a divergence in the engine cannot be blamed on (or hidden
   by) the 1.1% NER gap. This isolates the orchestration logic, which is what
   M4 actually ports.

2. The **results** of `analyze()` under a matrix of option sets: default,
   entity filters, explicit thresholds, allow lists in both match modes, and
   explicit context words. Options are what the engine is *for*, so testing
   only the default call would leave most of it unverified.

The engine is built with the NLP recognizer included, so PERSON/LOCATION
results are in scope and the SpacyRecognizer port is exercised too.

Usage:
    python3 Tools/analyzer_reference.py --python <venv python> \\
        --texts <json array of strings> \\
        --out Tests/PresidioConformance/Fixtures/analyzer_reference.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

CHILD = r'''
import json, sys
from presidio_analyzer import AnalyzerEngine
from presidio_analyzer.nlp_engine import SpacyNlpEngine

texts = json.load(open(sys.argv[1]))
model = sys.argv[2]

engine = AnalyzerEngine(
    supported_languages=["en"],
    nlp_engine=SpacyNlpEngine(models=[{"lang_code": "en", "model_name": model}]),
)

# The option matrix. Each entry is (name, kwargs); every one runs over every
# text so a divergence can be attributed to a specific option rather than to
# "something in the engine".
CASES = [
    ("default", {}),
    ("entities_subset", {"entities": ["PHONE_NUMBER", "EMAIL_ADDRESS", "PERSON"]}),
    ("threshold_0_5", {"score_threshold": 0.5}),
    ("threshold_0_85", {"score_threshold": 0.85}),
    ("context_words", {"context": ["credit", "card", "passport", "phone"]}),
    ("allow_exact", {"allow_list": ["David", "212-555-5555", "example.com"]}),
    ("allow_regex", {"allow_list": [r"\d{3}-\d{3}-\d{4}", "example"],
                     "allow_list_match": "regex"}),
]

def artifacts_of(text):
    a = engine.nlp_engine.process_text(text, "en")
    return {
        "tokens": [t.text for t in a.tokens],
        "token_indices": list(a.tokens_indices),
        "lemmas": list(a.lemmas),
        "keywords": list(a.keywords),
        "entities": [
            {"text": e.text, "label": e.label_,
             "start": e.start_char, "end": e.end_char}
            for e in a.entities
        ],
        "scores": [float(s) for s in a.scores],
    }

out = []
for text in texts:
    art = artifacts_of(text)
    runs = {}
    for name, kwargs in CASES:
        rs = engine.analyze(text=text, language="en", **kwargs)
        runs[name] = sorted(
            [
                {
                    "entity": r.entity_type,
                    "start": r.start,
                    "end": r.end,
                    "score": round(float(r.score), 10),
                }
                for r in rs
            ],
            key=lambda d: (d["start"], d["end"], d["entity"], d["score"]),
        )
    out.append({"text": text, "artifacts": art, "runs": runs})

json.dump({
    "model": model,
    "cases": [name for name, _ in CASES],
    "texts": out,
}, sys.stdout, ensure_ascii=False)
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True)
    ap.add_argument("--texts", required=True)
    ap.add_argument("--model", default="en_core_web_lg")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proc = subprocess.run(
        [args.python, "-c", CHILD, args.texts, args.model],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        print(proc.stderr[-4000:], file=sys.stderr)
        return 2

    payload = json.loads(proc.stdout)
    payload["schema_version"] = 1

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")

    total = sum(len(t["runs"][c]) for t in payload["texts"] for c in payload["cases"])
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  {len(payload['texts'])} texts x {len(payload['cases'])} option sets")
    print(f"  {total} expected results")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
