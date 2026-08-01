#!/usr/bin/env python3
"""Record BatchAnalyzerEngine behaviour as a differential oracle.

Covers what the class actually adds over `AnalyzerEngine.analyze`: how keys
become context, which values are skipped as falsy, and how `keys_to_skip`
propagates into nested dictionaries.

Usage:
    python3 Tools/batch_reference.py --python <venv python> \\
        --out Tests/PresidioConformance/Fixtures/batch_reference.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

CHILD = r'''
import json, sys
from presidio_analyzer import AnalyzerEngine, BatchAnalyzerEngine
from presidio_analyzer.nlp_engine import SpacyNlpEngine

engine = AnalyzerEngine(
    supported_languages=["en"],
    nlp_engine=SpacyNlpEngine(models=[{"lang_code": "en", "model_name": "en_core_web_lg"}]),
)
batch = BatchAnalyzerEngine(analyzer_engine=engine)

def dump(results):
    return sorted(
        [{"entity": r.entity_type, "start": r.start, "end": r.end,
          "score": round(float(r.score), 10)} for r in results],
        key=lambda d: (d["start"], d["end"], d["entity"], d["score"]),
    )

ITERATOR_CASES = [
    ["my card is 4095-2609-9393-4932", "call 212-555-5555", "a@example.com"],
    ["", "no pii here", "0"],
]

# (name, input_dict, keys_to_skip)
DICT_CASES = [
    ("keys_as_context",
     {"credit_card": "4095-2609-9393-4932", "notes": "4095-2609-9393-4932"}, []),
    ("falsy_values_skipped",
     {"empty": "", "zero": 0, "false": False, "real": "a@example.com"}, []),
    ("keys_to_skip",
     {"email": "a@example.com", "phone": "212-555-5555"}, ["phone"]),
    ("nested",
     {"outer": {"email": "a@example.com", "inner": {"phone": "212-555-5555"}},
      "top": "4095-2609-9393-4932"}, []),
    ("nested_keys_to_skip",
     {"outer": {"email": "a@example.com", "phone": "212-555-5555"}},
     ["outer.phone"]),
    ("list_value",
     {"emails": ["a@example.com", "b@example.com"], "n": 42}, []),
    ("primitive_types",
     {"num": 4095260993934932, "flag": True, "flt": 3.5}, []),
]

def walk(results):
    """Normalize analyze_dict output into a comparable tree."""
    out = []
    for item in results:
        rr = item.recognizer_results
        if isinstance(rr, list) and rr and isinstance(rr[0], list):
            shaped = {"kind": "list", "results": [dump(x) for x in rr]}
        elif isinstance(rr, list):
            shaped = {"kind": "single", "results": dump(rr)}
        else:
            shaped = {"kind": "nested", "results": walk(rr)}
        out.append({"key": item.key, "value": repr(item.value), **shaped})
    return out

payload = {
    "iterator": [
        {"texts": texts, "results": [dump(r) for r in batch.analyze_iterator(texts=texts, language="en")]}
        for texts in ITERATOR_CASES
    ],
    "dicts": [
        {"name": name, "input": repr(d), "keys_to_skip": skip,
         "results": walk(list(batch.analyze_dict(input_dict=d, language="en", keys_to_skip=skip)))}
        for name, d, skip in DICT_CASES
    ],
}
json.dump(payload, sys.stdout, ensure_ascii=False)
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proc = subprocess.run([args.python, "-c", CHILD], capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stderr[-4000:], file=sys.stderr)
        return 2

    payload = json.loads(proc.stdout)
    payload["schema_version"] = 1
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  {len(payload['iterator'])} iterator cases, {len(payload['dicts'])} dict cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
