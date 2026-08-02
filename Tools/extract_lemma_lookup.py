#!/usr/bin/env python3
"""Extract spaCy's English lemma lookup table.

Two scopes, because shipping the whole table makes results *worse*.

spaCy's English pipeline lemmatizes in **rule** mode, which needs POS tags and
therefore the tagger. `lemma_lookup` is the POS-free table used in lookup mode,
so it is not what the pipeline does — it is a different approximation.

Measured against spaCy's real lemmas over 11,223 tokens:

    lowercase          86.25% agreement
    full lemma_lookup  96.87%
    -ies subset        86.86%

The full table wins on raw agreement and loses where it counts. It stems
"number" to "numb" (61 occurrences in the sample), and "number" is a context
word for 36 recognizers — so a phone number written "My number is ..." drops
from 0.75 to 0.4. On context-heavy text the full table diverged from Presidio
on 2 of 10 texts where lowercase diverged on none.

The `-ies` subset closes the only gap the context vocabulary actually exposes
(6 of 523 context words, all the `-y -> -ies` plural) with **zero** regressions
against lowercase. That is what ships by default; the full table is extracted
too, for callers who want it and have read the above.

Usage:
    python3 Tools/extract_lemma_lookup.py --python <venv python> \\
        --out Sources/PresidioEngine/Resources/en_lemma_lookup.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

CHILD = r'''
import gzip, json, os, sys
import spacy_lookups_data

root = os.path.join(os.path.dirname(spacy_lookups_data.__file__), "data")
with gzip.open(os.path.join(root, "en_lemma_lookup.json.gz"), "rt", encoding="utf-8") as fh:
    lookup = json.load(fh)

# Only entries that change something, and keyed by the lowercase surface form:
# the consumer lowercases before looking up, and spaCy's own lookup falls back
# from the exact form to the lowercased one.
def useful(table):
    out = {}
    for surface, lemma in table.items():
        key = surface.lower()
        if lemma.lower() == key:
            continue
        out.setdefault(key, lemma.lower())
    return out

full = useful(lookup)
plurals = {k: v for k, v in full.items() if k.endswith("ies")}

json.dump({
    "plurals": plurals,
    "full": full,
}, sys.stdout, ensure_ascii=False)
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proc = subprocess.run(
        [args.python, "-c", CHILD], capture_output=True, text=True
    )
    if proc.returncode != 0:
        print(proc.stderr[-3000:], file=sys.stderr)
        return 2

    tables = json.loads(proc.stdout)
    payload = {
        "schema_version": 1,
        "source": "spacy-lookups-data en_lemma_lookup",
        "license": "MIT; the English lemma tables derive from WordNet 3.0",
        "note": (
            "spaCy's English pipeline uses rule mode, which needs POS. This is "
            "the POS-free lookup table, so it is an approximation of a "
            "different kind — see Tools/extract_lemma_lookup.py for the "
            "measurement that decided which scope ships by default."
        ),
        "plurals": tables["plurals"],
        "full": tables["full"],
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")

    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  plurals {len(payload['plurals'])}, full {len(payload['full'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
