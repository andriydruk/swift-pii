#!/usr/bin/env python3
"""Extract spaCy's attribute-ruler POS and lemma assignments.

Rule-mode lemmatization keys off the coarse POS tag, and POS comes from this
component rather than the tagger -- the tagger emits fine-grained Penn Treebank
tags. The ruler also assigns some lemmas outright ("was" -> "be", "me" -> "I")
before the lemmatizer ever runs.

Of the 130 rules that set POS, 122 are decidable from the tag and the token's
lowercase form. The other **6 need the dependency parser**, which this port does
not have, so they are recorded separately rather than silently dropped:

    TAG=CC  LOWER=but  DEP=advmod                    -> ADV
    TAG!=TO DEP in {aux, auxpass}                    -> AUX
    LOWER in {do, does, ...} DEP in {ROOT, ...}      -> VERB
    TAG=IN  DEP=mark                                 -> SCONJ
    DEP not in {det, quantmod} TAG in {DT, WDT}      -> PRON
    DEP=expl followed by a copula                    -> VERB

Order is preserved: spaCy applies the rules in sequence and a later one
overwrites an earlier one.

Usage:
    python3 Tools/extract_attribute_ruler.py --python <venv python> \\
        --model <dir> --out Sources/PresidioNLP/Resources/attribute_ruler.json
"""

from __future__ import annotations

import argparse, json, os, subprocess, sys

CHILD = r'''
import json, sys, srsly

model = sys.argv[1]
patterns = srsly.msgpack_loads(open(model + "/attribute_ruler/patterns", "rb").read())

simple, needs_dep = [], []
for rule in patterns:
    attrs = rule["attrs"]
    if not ({"POS", "LEMMA", "MORPH"} & set(attrs)):
        continue
    tokens = rule["patterns"][0]
    if len(tokens) != 1:
        needs_dep.append(rule); continue
    spec = tokens[0]
    if set(spec.keys()) - {"TAG", "LOWER"}:
        needs_dep.append(rule); continue

    def values(key):
        v = spec.get(key)
        if v is None: return None
        if isinstance(v, dict):
            return v.get("IN")       # NOT_IN cannot be enumerated
        return [v]

    tags, lowers = values("TAG"), values("LOWER")
    if (spec.get("TAG") is not None and tags is None) or \
       (spec.get("LOWER") is not None and lowers is None):
        needs_dep.append(rule); continue

    simple.append({
        "tags": tags, "lowers": lowers,
        "pos": attrs.get("POS"), "lemma": attrs.get("LEMMA"),
        # `is_base_form` reads Number, VerbForm, Tense and Degree, so MORPH is
        # not optional even though lemmatization never prints it.
        "morph": attrs.get("MORPH"),
    })

json.dump({
    "rules": simple,
    "requires_parser": len(needs_dep),
    "requires_parser_detail": [
        {"pattern": r["patterns"], "attrs": {k: v for k, v in r["attrs"].items()
                                             if k in ("POS", "LEMMA")}}
        for r in needs_dep
    ],
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
    print(f"  {len(payload['rules'])} decidable rules, "
          f"{payload['requires_parser']} need the parser")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
