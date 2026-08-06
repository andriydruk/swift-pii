#!/usr/bin/env python3
"""Extract a spaCy language's tokenizer rules and NORM tables.

The tokenizer is rule-based and entirely data-driven: four regexes plus a
special-case table. That makes it portable, unlike the statistical components.

NORMs are extracted alongside because the NER model consumes them as a feature,
and they are *not* simply the lowercase form. Resolution order, determined
empirically against spaCy rather than from documentation:

  1. If the token came from a tokenizer exception, that exception piece's NORM.
     This is per-(exception, piece), not per surface form -- "gonna" splits into
     pieces with NORMs "going"/"to", but a bare "a" elsewhere normalizes to "a".
  2. `lexeme_norm[exact_surface_form]` -- keyed by the exact text, NOT
     lowercased. "licence" maps to "license" but "PLZ" does not map to "please",
     because only "plz" is a key.
  3. `BASE_NORMS[exact]` -- punctuation folding (backtick to apostrophe,
     em-dash to hyphen).
  4. Otherwise the lowercase form.

Language is a parameter, not a constant. The rules differ per language --
German splits on different infixes and has its own exception table -- but the
*shape* of the data is identical, so one extractor and one Swift reader serve
every rule-tokenized language. (Japanese and Chinese are not rule-tokenized at
all; they need SudachiPy and pkuseg respectively, and are out of reach here.)

Usage:
    python3 Tools/extract_tokenizer.py --python <venv python with spacy> \\
        --lang de --out Sources/PresidioNLP/Resources/de_tokenizer.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

# Runs inside the target interpreter, which is the only one that has spaCy.
CHILD = r'''
import gzip, importlib, json, os, sys
import spacy
from spacy.lang.norm_exceptions import BASE_NORMS
from spacy.symbols import NORM, ORTH

lang = sys.argv[1]

# Not every language defines tokenizer_exceptions; an absent module means the
# language simply has none, which is different from failing to read it.
try:
    TOKENIZER_EXCEPTIONS = importlib.import_module(
        f"spacy.lang.{lang}.tokenizer_exceptions"
    ).TOKENIZER_EXCEPTIONS
except (ImportError, AttributeError):
    TOKENIZER_EXCEPTIONS = {}

nlp = spacy.blank(lang)
tok = nlp.tokenizer

def pattern(matcher):
    return matcher.__self__.pattern if matcher is not None else None

# Special cases: key -> [{orth, norm}]. NORM is per piece, so the pairing must
# be preserved rather than flattened into a surface-form map.
specials = {}
for key, pieces in TOKENIZER_EXCEPTIONS.items():
    out = []
    for p in pieces:
        orth = p.get(ORTH, p.get("ORTH"))
        norm = p.get(NORM, p.get("NORM"))
        out.append({"orth": orth, "norm": norm})
    specials[key] = out

lexeme_norm = {}
try:
    import spacy_lookups_data
    path = os.path.join(os.path.dirname(spacy_lookups_data.__file__),
                        "data", f"{lang}_lexeme_norm.json.gz")
    with gzip.open(path, "rt", encoding="utf8") as fh:
        lexeme_norm = json.load(fh)
except Exception as exc:  # noqa: BLE001
    print(f"WARN: lexeme_norm unavailable: {exc}", file=sys.stderr)

json.dump({
    "spacy_version": spacy.__version__,
    "language": lang,
    "prefix": pattern(tok.prefix_search),
    "suffix": pattern(tok.suffix_search),
    "infix": pattern(tok.infix_finditer),
    "url": pattern(tok.url_match),
    "token_match": pattern(tok.token_match),
    "specials": specials,
    "base_norms": dict(BASE_NORMS),
    "lexeme_norm": lexeme_norm,
}, sys.stdout, ensure_ascii=False)
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True, help="interpreter that has spacy")
    ap.add_argument("--lang", default="en", help="spaCy language code, e.g. en or de")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proc = subprocess.run(
        [args.python, "-c", CHILD, args.lang], capture_output=True, text=True
    )
    if proc.returncode != 0:
        print(proc.stderr, file=sys.stderr)
        return 2
    for line in proc.stderr.splitlines():
        if line.startswith("WARN"):
            print(line, file=sys.stderr)

    payload = json.loads(proc.stdout)
    payload["schema_version"] = 1

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")

    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  spaCy         {payload['spacy_version']}  language {payload['language']}")
    for key in ("prefix", "suffix", "infix", "url"):
        value = payload.get(key)
        print(f"  {key:13s} {len(value) if value else 'None'} chars")
    print(f"  specials      {len(payload['specials'])}")
    print(f"  base_norms    {len(payload['base_norms'])}")
    print(f"  lexeme_norm   {len(payload['lexeme_norm'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
