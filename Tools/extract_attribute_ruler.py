#!/usr/bin/env python3
"""Extract spaCy's attribute ruler: every rule, in order, as a token pattern.

Rule-mode lemmatization keys off the coarse POS tag, and POS comes from this
component rather than from the tagger -- the tagger emits fine-grained Penn
Treebank tags. The ruler also assigns some lemmas outright ("was" -> "be", "me"
-> "I") before the lemmatizer ever runs.

An earlier version of this script flattened each rule to a `(tags, lowers)` pair
and put the ones that would not flatten into a separate `requires_parser_detail`
list that nothing read. That lost two things. It lost the 22 rules themselves --
the ones testing `DEP`, matching two tokens, or using `NOT_IN`/`REGEX` -- and,
less obviously, it lost their **position**. spaCy sorts matches by pattern index
and applies them in that order, so a rule pulled out of the sequence cannot be
put back at the end: rule 173 setting `PRON` has to run after rule 47 setting
`DET`, or `WDT` comes out wrong.

It also silently dropped alternatives. Rule 175 is `[[VBZ gets], [VBD got]]` and
only the first was kept, so `got` -> `get` was never applied.

So this emits all 179 rules in order, each as spaCy's own structure. The pattern
vocabulary is small and closed, which is what makes a faithful matcher on the
Swift side about a hundred lines:

    keys        TAG, LOWER, DEP, IS_SPACE
    operators   literal, IN, NOT_IN, REGEX
    length      1 or 2 tokens; `index` picks which one is annotated
    attrs       POS, MORPH, LEMMA, and one rule each setting TAG and DEP

The empty string in a `NOT_IN` list is spaCy's "unset": an unparsed token's DEP
is string id 0, which is `""`. That convention is why the Swift side needs no
separate no-parser code path -- with no dependency labels every `DEP` constraint
simply fails to match, which is exactly the behaviour of a pipeline without a
parser.

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

KEYS = {"TAG": "tag", "LOWER": "lower", "DEP": "dep"}


def constraint(value):
    """One attribute test, in the four forms spaCy's Matcher uses here."""
    if not isinstance(value, dict):
        return {"eq": value}
    if "IN" in value:
        return {"in": list(value["IN"])}
    if "NOT_IN" in value:
        return {"not_in": list(value["NOT_IN"])}
    if "REGEX" in value:
        return {"regex": value["REGEX"]}
    raise SystemExit(f"unsupported operator in {value!r}")


def token_pattern(spec):
    out = {}
    for key, value in spec.items():
        if key in KEYS:
            out[KEYS[key]] = constraint(value)
        elif key == "IS_SPACE":
            out["is_space"] = bool(value)
        else:
            raise SystemExit(f"unsupported pattern key {key!r}")
    return out


rules = []
for rule in patterns:
    attrs = rule["attrs"]
    rules.append({
        "alternatives": [
            [token_pattern(spec) for spec in alternative]
            for alternative in rule["patterns"]
        ],
        # Which token of the match gets the attributes. Negative counts from the
        # end, as Span indexing does.
        "index": rule["index"],
        "pos": attrs.get("POS"),
        "lemma": attrs.get("LEMMA"),
        # `is_base_form` reads Number, VerbForm, Tense and Degree, so MORPH is
        # not optional even though lemmatization never prints it.
        "morph": attrs.get("MORPH"),
        "tag": attrs.get("TAG"),
        "dep": attrs.get("DEP"),
    })

needs_dep = sum(
    1 for rule in rules
    for alternative in rule["alternatives"]
    if any("dep" in spec for spec in alternative)
)

json.dump({
    "rules": rules,
    "requires_parser": needs_dep,
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
    # Bumped from 1: the shape changed from flattened (tags, lowers) pairs to
    # ordered token patterns, and the Swift loader rejects the old shape rather
    # than reading half of it.
    payload["schema_version"] = 2
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")

    multi = sum(
        1 for rule in payload["rules"]
        if any(len(alternative) > 1 for alternative in rule["alternatives"])
    )
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  {len(payload['rules'])} rules, {payload['requires_parser']} testing DEP, "
          f"{multi} spanning two tokens")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
