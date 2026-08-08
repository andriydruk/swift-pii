#!/usr/bin/env python3
"""Record spaCy's dependency parse for the English NER corpus.

The port already reproduces spaCy's NER exactly *without* the parser. The
residual divergence is entirely sentence boundaries: spaCy refuses to open or
extend an entity when the next token starts a sentence, and those boundaries
come from the parser. So the parser is the last component between this port and
exact parity, and this is its differential corpus.

Recorded per text: `heads` as **absolute token indices**, two sets of
dependency labels, and `sent_starts` as the token indices that begin a sentence.

The texts come from the NER corpus verbatim -- including its adversarial half,
which `ner_reference.py` owns. Reading them rather than re-deriving them is what
makes "the same input" literally true, so a parser divergence and an NER
divergence on one text are attributable to each other.

Heads and labels are what the parser predicts; `sent_starts` is what NER actually
consumes, and it is derived from the heads rather than predicted directly -- it is
the left edge of every subtree whose root is its own head. Recording all three
means a divergence can be localised to the transitions, the deprojectivisation, or
the edge computation, instead of just "the boundaries are wrong".

**Two label sets**, because there are two answers and conflating them hid a real
mistake. `parser_deps` is what the parser itself produces; `deps` is what the
document ends up with after the attribute ruler, which runs *after* the parser and
rewrites one thing -- a whitespace token that has a dependency becomes `dep`. In a
document that is nothing but whitespace, that token is its own head, so the parser
calls it `ROOT` and the ruler calls it `dep`. Comparing a parser against the full
pipeline's labels reports that as four divergences in 50,744: not a parser bug,
and not nothing either. It is the layering, and the fixture now says which layer
it is being asked about.

Token texts and offsets are deliberately *not* recorded. The tokenizer corpus
already asserts them exhaustively over this same input, and repeating them here
quadrupled the file for no additional signal; a token-count mismatch is enough
to detect misalignment, and the tokenizer suite says what caused it.

    python3 Tools/parser_reference.py \\
        --python .venv/bin/python \\
        --out Tests/PresidioConformance/Fixtures/parser_gold_sm.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TEXTS = os.path.join(
    HERE, "..", "Tests", "PresidioConformance", "Fixtures", "ner_gold_sm.json"
)

# Runs inside the venv that has spaCy, so it cannot import anything from here.
CHILD = r'''
import json
import sys

import spacy

texts = json.load(sys.stdin)
nlp = spacy.load("en_core_web_sm")
# The parser's own labels, before the attribute ruler rewrites any of them. The
# lemmatizer is excluded too because it depends on the ruler's POS.
unruled = spacy.load("en_core_web_sm", exclude=["attribute_ruler", "lemmatizer"])

cases = []
for text in texts:
    doc = nlp(text)
    raw = unruled(text)
    assert len(doc) == len(raw), text
    cases.append({
        "text": text,
        "heads": [token.head.i for token in doc],
        "deps": [token.dep_ for token in doc],
        "parser_deps": [token.dep_ for token in raw],
        "sent_starts": [token.i for token in doc if token.is_sent_start],
    })

meta = nlp.meta
json.dump(
    {
        "model": f"{meta['lang']}_{meta['name']}-{meta['version']}",
        "spacy_version": spacy.__version__,
        "cases": cases,
    },
    sys.stdout,
    ensure_ascii=False,
)
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--python",
        default=".venv/bin/python",
        help="interpreter with spacy and en_core_web_sm installed",
    )
    parser.add_argument(
        "--texts",
        default=DEFAULT_TEXTS,
        help="corpus to parse; the NER gold file, so both are measured on the same input",
    )
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    with open(args.texts, encoding="utf-8") as handle:
        texts = [case["text"] for case in json.load(handle)["cases"]]

    result = subprocess.run(
        [args.python, "-c", CHILD],
        input=json.dumps(texts),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        return result.returncode

    gold = json.loads(result.stdout)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(gold, handle, ensure_ascii=False)
        handle.write("\n")

    sentences = sum(len(case["sent_starts"]) for case in gold["cases"])
    tokens = sum(len(case["heads"]) for case in gold["cases"])
    ruled = sum(
        1 for case in gold["cases"]
        for a, b in zip(case["deps"], case["parser_deps"]) if a != b
    )
    print(
        f"{args.out}: {len(gold['cases'])} texts, {tokens} tokens, "
        f"{sentences} sentences, from {gold['model']}"
    )
    print(f"  {ruled} labels the attribute ruler rewrites after the parser")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
