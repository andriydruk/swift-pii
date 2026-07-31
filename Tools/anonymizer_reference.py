#!/usr/bin/env python3
"""Generate the anonymizer differential reference by running real Presidio.

The anonymizer's own tests are imperative rather than table-driven, so there is
nothing to harvest the way the recognizer tables were. But `presidio_anonymizer`
imports standalone — its only runtime dependency is `cryptography` — so it can
be driven directly as an oracle. That is strictly better than porting
assertions: it covers the engine's *behaviour*, including the parts no upstream
test pins down.

The scenario matrix targets what is actually subtle: right-to-left span
rewriting, index normalization, overlap/containment resolution, same-type
merging, whitespace merging, and non-BMP offsets.

Usage:
    python3 Tools/anonymizer_reference.py \\
        --presidio <checkout> \\
        --out Tests/PresidioConformance/Fixtures/anonymizer_reference.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# A fixed salt so the hash operator is reproducible. Upstream defaults to
# os.urandom(32), which cannot be differentially tested.
FIXED_SALT = "0123456789abcdef0123456789abcdef"


def build_scenarios(RecognizerResult, OperatorConfig):
    """(name, text, [RecognizerResult], {entity: OperatorConfig}, kwargs)."""
    S = RecognizerResult
    C = OperatorConfig
    out = []

    def add(name, text, results, operators=None, **kwargs):
        out.append((name, text, results, operators or {}, kwargs))

    # --- Operators, each over the same simple text ------------------------
    text = "My name is Bond, James Bond"
    person = [S("PERSON", 11, 15, 0.8), S("PERSON", 17, 27, 0.8)]
    add("replace-default", text, person)
    add("replace-value", text, person, {"PERSON": C("replace", {"new_value": "BIP"})})
    add("replace-empty-value", text, person, {"PERSON": C("replace", {"new_value": ""})})
    add("redact", text, person, {"PERSON": C("redact", {})})
    add("keep", text, person, {"PERSON": C("keep", {})})
    for chars, from_end, char in [(4, False, "*"), (4, True, "*"), (100, False, "#"),
                                  (0, False, "*"), (-1, False, "*"), (2, True, "0")]:
        add(
            f"mask-{chars}-{from_end}-{char}", text, person,
            {"PERSON": C("mask", {"chars_to_mask": chars, "from_end": from_end,
                                  "masking_char": char})},
        )
    for hash_type in ["sha256", "sha512"]:
        add(
            f"hash-{hash_type}", text, person,
            {"PERSON": C("hash", {"hash_type": hash_type, "salt": FIXED_SALT})},
        )

    # --- Defaults and per-entity operators --------------------------------
    mixed = [S("PERSON", 11, 15, 0.8), S("LOCATION", 17, 27, 0.8)]
    add("per-entity-operators", text, mixed,
        {"PERSON": C("redact", {}), "LOCATION": C("replace", {"new_value": "LOC"})})
    add("default-fallback", text, mixed, {"DEFAULT": C("redact", {})})
    add("partial-config-uses-default", text, mixed, {"PERSON": C("redact", {})})

    # --- Conflict resolution ---------------------------------------------
    conflict_text = "Hello Mr. John Smith of Acme Corporation, phone 555-1234."
    add("contained-dropped", conflict_text, [
        S("FULL_NAME", 10, 20, 0.6), S("FIRST_NAME", 10, 14, 0.9),
        S("LAST_NAME", 15, 20, 0.6),
    ])
    add("equal-indices-higher-score-wins", conflict_text, [
        S("A", 10, 20, 0.4), S("B", 10, 20, 0.9),
    ])
    add("same-type-overlap-merges", conflict_text, [
        S("PERSON", 10, 16, 0.5), S("PERSON", 14, 20, 0.5),
    ])
    add("same-type-adjacent-no-merge", conflict_text, [
        S("PERSON", 10, 14, 0.5), S("PERSON", 15, 20, 0.5),
    ])
    add("different-type-overlap-kept", conflict_text, [
        S("A", 10, 16, 0.5), S("B", 14, 20, 0.5),
    ])
    add("nested-three-deep", conflict_text, [
        S("OUTER", 6, 40, 0.5), S("MIDDLE", 10, 20, 0.6), S("INNER", 10, 14, 0.9),
    ])
    add("unsorted-input", conflict_text, [
        S("PERSON", 24, 40, 0.5), S("PERSON", 10, 20, 0.5), S("PHONE", 47, 55, 0.5),
    ])

    # --- Whitespace merging ----------------------------------------------
    add("space-merge", "John Smith lives here", [
        S("PERSON", 0, 4, 0.8), S("PERSON", 5, 10, 0.8),
    ])
    add("space-merge-disabled", "John Smith lives here", [
        S("PERSON", 0, 4, 0.8), S("PERSON", 5, 10, 0.8),
    ], merge_entities_with_spaces=False)
    add("space-merge-multiple-spaces", "John   Smith lives", [
        S("PERSON", 0, 4, 0.8), S("PERSON", 7, 12, 0.8),
    ])
    add("space-merge-different-types", "John Smith lives", [
        S("PERSON", 0, 4, 0.8), S("LOCATION", 5, 10, 0.8),
    ])
    add("space-merge-tab-not-space", "John\tSmith lives", [
        S("PERSON", 0, 4, 0.8), S("PERSON", 5, 10, 0.8),
    ])

    # --- Span edge cases --------------------------------------------------
    add("whole-text", "SecretValue", [S("SECRET", 0, 11, 0.9)])
    add("zero-length-span", "hello world", [S("X", 5, 5, 0.5)])
    add("span-at-start", "hello world", [S("X", 0, 5, 0.5)])
    add("span-at-end", "hello world", [S("X", 6, 11, 0.5)])
    add("adjacent-spans", "abcdef", [S("X", 0, 3, 0.5), S("Y", 3, 6, 0.5)])
    add("no-entities", "nothing to do here", [])
    add("empty-text", "", [])

    # --- Unicode ----------------------------------------------------------
    add("emoji-before-span", "\U0001F608 Bond is here", [S("PERSON", 2, 6, 0.8)])
    add("emoji-inside-span", "call \U0001F608\U0001F608 now", [S("X", 5, 7, 0.8)])
    add("combining-marks", "café Bond", [S("PERSON", 6, 10, 0.8)])
    add("cjk", "田中さん is here", [S("PERSON", 0, 4, 0.8)])
    add("rtl-hebrew", "שלום Bond", [S("PERSON", 5, 9, 0.8)])
    add("emoji-replacement", "Bond is here",
        [S("PERSON", 0, 4, 0.8)], {"PERSON": C("replace", {"new_value": "\U0001F600"})})

    # --- Conflict strategies ---------------------------------------------
    from presidio_anonymizer.entities import ConflictResolutionStrategy as CRS
    for strategy in [CRS.MERGE_SIMILAR_OR_CONTAINED, CRS.REMOVE_INTERSECTIONS]:
        add(f"strategy-{strategy.value}-overlap", conflict_text, [
            S("A", 10, 18, 0.9), S("B", 14, 25, 0.5),
        ], conflict_resolution=strategy)

    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--presidio", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    pkg = os.path.join(args.presidio, "presidio-anonymizer")
    if not os.path.isdir(pkg):
        print(f"error: {pkg} not found", file=sys.stderr)
        return 2
    sys.path.insert(0, pkg)

    from presidio_anonymizer import AnonymizerEngine
    from presidio_anonymizer.entities import RecognizerResult, OperatorConfig

    engine = AnonymizerEngine()
    scenarios = build_scenarios(RecognizerResult, OperatorConfig)

    cases = []
    failures = 0
    for name, text, results, operators, kwargs in scenarios:
        entry = {
            "name": name,
            "text": text,
            "analyzer_results": [
                {"entity_type": r.entity_type, "start": r.start,
                 "end": r.end, "score": r.score}
                for r in results
            ],
            "operators": {
                key: {"operator_name": cfg.operator_name,
                      "params": {k: v for k, v in cfg.params.items()}}
                for key, cfg in operators.items()
            },
            "merge_entities_with_spaces": kwargs.get("merge_entities_with_spaces", True),
            "conflict_resolution": getattr(
                kwargs.get("conflict_resolution"), "value", "merge_similar_or_contained"
            ),
        }
        try:
            out = engine.anonymize(text, list(results), operators or None, **kwargs)
            entry["result"] = {
                "text": out.text,
                "items": [
                    {"start": i.start, "end": i.end, "entity_type": i.entity_type,
                     "text": i.text, "operator": i.operator}
                    for i in out.items
                ],
            }
        except Exception as exc:  # noqa: BLE001 - the error IS the expectation
            failures += 1
            entry["error"] = f"{type(exc).__name__}: {exc}"
        cases.append(entry)

    payload = {
        "schema_version": 1,
        "note": "Generated by running real presidio_anonymizer as an oracle.",
        "fixed_salt": FIXED_SALT,
        "stats": {"cases": len(cases), "errors": failures},
        "cases": cases,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  cases  {len(cases)}")
    print(f"  errors {failures} (expected-failure cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
