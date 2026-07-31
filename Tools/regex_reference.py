#!/usr/bin/env python3
"""Generate the regex differential reference: Python `regex` match spans.

Runs every extracted Presidio pattern over every text in the conformance
corpus and records the exact match spans. The Swift engine must reproduce this
byte for byte.

The corpus texts are real PII samples taken from Presidio's own tests, so this
exercises the patterns on the input they were written for rather than on
synthetic strings.

Presidio compiles every pattern with DOTALL|MULTILINE|IGNORECASE
(``pattern_recognizer.py:59``), so this does too.

Usage:
    python3 Tools/regex_reference.py \\
        --patterns Sources/PresidioRecognizers/Resources/recognizers.json \\
        --texts Tests/PresidioConformance/Fixtures/recognizer_cases.json \\
        --out Tests/PresidioConformance/Fixtures/regex_reference.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys

try:
    import regex
except ImportError:  # pragma: no cover
    print("error: pip install regex", file=sys.stderr)
    raise SystemExit(2)

# pattern_recognizer.py:59 -- global_regex_flags on every Presidio pattern.
FLAGS = regex.DOTALL | regex.MULTILINE | regex.IGNORECASE

# A pathological pattern on a pathological input can hang the reference build.
# Presidio itself passes timeout=60 to finditer for the same reason.
TIMEOUT_SECONDS = 20


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--patterns", required=True)
    ap.add_argument("--texts", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.patterns, encoding="utf-8") as fh:
        recognizers = json.load(fh)
    with open(args.texts, encoding="utf-8") as fh:
        corpus = json.load(fh)

    # Flatten patterns, keeping a stable identity the Swift side can match on.
    patterns = []
    for rec in recognizers["recognizers"]:
        for pat in rec["patterns"]:
            patterns.append(
                {
                    "recognizer": rec["class"],
                    "name": pat["name"],
                    "regex": pat["regex"],
                    # Per-recognizer, not global: IbanRecognizer drops
                    # IGNORECASE (iban_recognizer.py:77).
                    "flags": rec.get("flags", ["DOTALL", "MULTILINE", "IGNORECASE"]),
                }
            )

    # Deduplicate texts; many recognizers share short samples.
    seen: dict[str, int] = {}
    texts: list[str] = []
    for table in corpus["tables"]:
        for case in table["cases"]:
            t = case["text"]
            if t not in seen:
                seen[t] = len(texts)
                texts.append(t)

    print(f"patterns {len(patterns)}  texts {len(texts)}  "
          f"combinations {len(patterns) * len(texts)}")

    compiled = []
    uncompilable = []
    for i, p in enumerate(patterns):
        try:
            flags = 0
            for name in p["flags"]:
                flags |= getattr(regex, name)
            compiled.append(regex.compile(p["regex"], flags))
        except regex.error as exc:
            compiled.append(None)
            uncompilable.append({"index": i, "recognizer": p["recognizer"],
                                 "name": p["name"], "error": str(exc)})

    # results[pattern_index] = {text_index: [[start, end], ...]}
    # Only non-empty match lists are stored; absence means "no match", which is
    # itself an assertion the Swift side must satisfy.
    results: dict[str, dict[str, list[list[int]]]] = {}
    timeouts = []
    total_matches = 0

    for pi, rx in enumerate(compiled):
        if rx is None:
            continue
        per_text: dict[str, list[list[int]]] = {}
        for ti, text in enumerate(texts):
            try:
                # [start, end, g1_start, g1_end, g2_start, g2_end, ...]
                # A non-participating group is (-1, -1), as Python reports it.
                spans = []
                for m in rx.finditer(text, timeout=TIMEOUT_SECONDS):
                    row = [m.start(), m.end()]
                    for g in range(1, (m.re.groups or 0) + 1):
                        gs, ge = m.span(g)
                        row.extend([gs, ge])
                    spans.append(row)
            except TimeoutError:
                timeouts.append({"pattern": pi, "text": ti})
                continue
            if spans:
                per_text[str(ti)] = spans
                total_matches += len(spans)
        if per_text:
            results[str(pi)] = per_text

    payload = {
        "schema_version": 1,
        "regex_version": regex.__version__,
        "flags": "per-pattern; see patterns[].flags",
        "span_encoding": "[start, end, g1_start, g1_end, ...]; -1 means the group did not participate",
        "stats": {
            "patterns": len(patterns),
            "texts": len(texts),
            "total_matches": total_matches,
            "uncompilable": len(uncompilable),
            "timeouts": len(timeouts),
        },
        "patterns": patterns,
        "texts": texts,
        "matches": results,
        "uncompilable": uncompilable,
        "timeouts": timeouts,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")

    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    for k, v in payload["stats"].items():
        print(f"  {k:16s} {v}")
    for u in uncompilable:
        print(f"  UNCOMPILABLE {u['recognizer']}/{u['name']}: {u['error']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
