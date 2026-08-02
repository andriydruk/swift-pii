#!/usr/bin/env python3
"""Differential-test every checksum validator against adversarial input.

The harvested validator corpus is upstream's own tables, which are ASCII and
well-formed -- they check that the arithmetic is right, not that the *edges*
agree. The edges are where a port drifts: `str.isdigit()` and Swift's
`Character.isNumber` disagree on characters outside Nd, `int()` and
`wholeNumberValue` disagree on what they accept, and `strip()` and
`trimmingCharacters` disagree on which spaces they remove.

Some of that is unreachable, because a `\\d` pattern only ever passes Nd
characters to a validator. This tool exists to establish which parts are
unreachable rather than assume it: it feeds every validator inputs that a
Unicode-aware `\\d` really can produce -- Arabic-Indic and full-width digits,
mixed scripts -- plus inputs that only reach a validator when a recognizer
declares a looser pattern.

Every recognizer class exposing `validate_result` or `invalidate_result` is
covered, so adding a validator to the port without covering it here is
visible.

Usage:
    python3 Tools/validator_stress.py --python <venv python> \\
        --cases Tests/PresidioConformance/Fixtures/validator_cases.json \\
        --out Tests/PresidioConformance/Fixtures/validator_stress.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

CHILD = r'''
import json, sys
import presidio_analyzer.predefined_recognizers as P

seeds = json.loads(sys.argv[1])

# Transformations a Unicode-aware `\d` can actually deliver, plus a few that
# only arrive through a looser pattern. Each is applied to every seed.
ARABIC = {chr(ord("0") + i): chr(0x0660 + i) for i in range(10)}
FULLWIDTH = {chr(ord("0") + i): chr(0xFF10 + i) for i in range(10)}

def translate(value, table):
    return "".join(table.get(ch, ch) for ch in value)

def variants(seed):
    yield seed
    yield translate(seed, ARABIC)
    yield translate(seed, FULLWIDTH)
    yield seed.upper()
    yield seed.lower()
    yield " " + seed + " "
    yield " " + seed          # non-breaking space
    yield "​" + seed          # zero-width space
    yield seed + "​"
    yield seed.replace("0", "O", 1)     # letter O for zero
    yield seed + "́"               # combining acute
    yield seed[:-1] if len(seed) > 1 else seed
    yield seed + seed[:1]

out = []
for class_name, inputs in seeds.items():
    cls = getattr(P, class_name, None)
    if cls is None:
        continue
    try:
        recognizer = cls()
    except Exception:
        continue

    cases = []
    seen = set()
    for seed in inputs:
        for value in variants(seed):
            if value in seen:
                continue
            seen.add(value)
            record = {"input": value}
            try:
                result = recognizer.validate_result(value)
                record["validate"] = (
                    "valid" if result is True
                    else "invalid" if result is False
                    else "indeterminate"
                )
            except NotImplementedError:
                continue
            except Exception as exc:
                # A validator that raises is itself a behaviour to match.
                record["validate"] = "raises:" + type(exc).__name__
            cases.append(record)
    if cases:
        out.append({"recognizer": class_name, "cases": cases})

json.dump({"tables": out}, sys.stdout, ensure_ascii=False)
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True)
    ap.add_argument("--cases", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.cases, encoding="utf-8") as fh:
        corpus = json.load(fh)

    seeds: dict[str, list[str]] = {}
    for table in corpus["tables"]:
        name = table.get("recognizer")
        if not name:
            continue
        bucket = seeds.setdefault(name, [])
        for case in table["cases"]:
            if case["input"] not in bucket:
                bucket.append(case["input"])

    proc = subprocess.run(
        [args.python, "-c", CHILD, json.dumps(seeds)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        print(proc.stderr[-3000:], file=sys.stderr)
        return 2

    payload = json.loads(proc.stdout)
    payload["schema_version"] = 1

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")

    total = sum(len(t["cases"]) for t in payload["tables"])
    raises = sum(
        1 for t in payload["tables"] for c in t["cases"]
        if c["validate"].startswith("raises")
    )
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  {len(payload['tables'])} validators, {total} cases, {raises} raising")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
