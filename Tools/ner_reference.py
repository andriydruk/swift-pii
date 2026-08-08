#!/usr/bin/env python3
"""Regenerate the English NER gold corpus from spaCy.

This fixture predates the rest of `Tools/` and had no generator, which made it
the one corpus in the repository that could not be re-derived. Every other one
fails loudly in CI if upstream changes shape; this one would have gone stale
silently, and the port measures its headline number against it.

**The texts are the input, not the output.** They are read back out of the
existing fixture, because that is where the harvested corpus lives -- 2,000 texts
of documentation and code prose, collected before this tool existed and not
reconstructible from anything else. What is regenerated is spaCy's *answers*. So
this is reproducibility of the gold, not of the sample.

The adversarial texts are shared with `parser_reference.py` rather than copied,
so the two corpora cannot drift apart in what they consider a hard case. It is
the same reason both read the same file: a parser divergence and an NER
divergence on the same input are attributable to each other, and on different
input they are not.

    python3 Tools/ner_reference.py \\
        --python .venv/bin/python \\
        --out Tests/PresidioConformance/Fixtures/ner_gold_sm.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(
    HERE, "..", "Tests", "PresidioConformance", "Fixtures", "ner_gold_sm.json"
)

# --- The adversarial half ---------------------------------------------------
#
# The 2,000 harvested texts are prose, and prose exercises the transition system
# in the shape it was trained on. These are the shapes it was not.
#
# They came from probing the Swift port for crashes. It did not crash, and the
# answers turned out to agree with spaCy -- which is exactly the sort of thing
# worth pinning *before* someone optimises the state machine, rather than
# discovering afterwards that it used to be right.
#
# Degenerate input bites hardest in the transitions: `Reduce` can push a token
# back onto the buffer and mark it unshiftable, `Break` may fire at most once per
# position, and the port carries fallbacks for "no valid action" and for a step
# budget that nothing has ever tripped. A 500-token run of bare sentence
# terminators is the closest thing to a stress test for that, and its answer is
# not the obvious one: spaCy marks three sentences, at 0, 2 and 498, not 250.
ADVERSARIAL = [
    # Nothing, and almost nothing.
    "",
    " ",
    "a",
    ".",
    "one two",
    # Whitespace tokens. spaCy emits a token for a run of whitespace, and both
    # the ruler's IS_SPACE patterns and NER's "may not begin on whitespace" rule
    # key off it -- so a document that is mostly whitespace is a different code
    # path, not just a boring one.
    "\n\n\n",
    "\t\t \n   \r\n ",
    " " * 30,
    "Anna   Muller  works   at   Siemens   AG",
    "Berlin \n\n Munich \n\n Hamburg",
    # Zero-width and combining marks: codepoints that are not graphemes, which is
    # the distinction every lexical feature is built on.
    "​",
    "a " + "́" * 50,
    "\U0001f600\U0001f600\U0001f600",
    "рекомендуя́ Москва́ сегодня́",
    # Length. 2,000 tokens is ~4,000 transitions in one document, an order of
    # magnitude past anything in the harvested corpus.
    "word " * 2000,
    ". " * 500,
    "Berlin, " * 300,
    # Fragments, and boundaries in unusual places -- no verb, no subject, a
    # boundary immediately after the first token.
    "Dr.",
    "du's",
    "Mr. and Mrs. Smith of Smith & Smith Ltd. v. Jones.",
    "A. B. C. D. E. F.",
    "?! ?! ?!",
    "-- Berlin -- Munich --",
    # Non-projective structures, which are what the pseudo-projective label
    # decoration exists for: extraposed relative clauses and long-distance
    # dependencies. If `deprojectivize` regresses, this is where it shows.
    "The report which David Johnson wrote about Berlin was published.",
    "Who did Sarah say that Microsoft hired in Seattle?",
    "A man arrived yesterday whom nobody in the Berlin office recognised.",
    "What Anna claimed the Siemens engineers had found was never confirmed.",
    # Tables and markup, which is where the sentence-boundary divergences in the
    # harvested corpus actually lived.
    "| | KR_PASSPORT| The Korean Passport Number | Pattern match, context.",
    "### Canada |FieldType|Description| |--- |--- | |CA_SIN|A number|",
]

CHILD = r'''
import json
import sys

import spacy

texts = json.load(sys.stdin)
nlp = spacy.load("en_core_web_sm")

cases = []
for text in texts:
    doc = nlp(text)
    cases.append({
        "text": text,
        "entities": [
            {
                "label": ent.label_,
                # Python string indices are codepoints, which is the offset model
                # this port carries end to end.
                "start": ent.start_char,
                "end": ent.end_char,
                "text": ent.text,
            }
            for ent in doc.ents
        ],
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
        default=DEFAULT_OUT,
        help="where the harvested texts are read from; defaults to the output file",
    )
    parser.add_argument("--out", default=DEFAULT_OUT)
    args = parser.parse_args()

    with open(args.texts, encoding="utf-8") as handle:
        harvested = [case["text"] for case in json.load(handle)["cases"]]
    # Anything already carried over from a previous run is dropped before the
    # adversarial half is re-appended, so running this twice is a no-op rather
    # than a corpus that grows by 29 texts each time.
    harvested = [text for text in harvested if text not in set(ADVERSARIAL)]
    texts = harvested + ADVERSARIAL

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

    entities = sum(len(case["entities"]) for case in gold["cases"])
    print(
        f"{args.out}: {len(gold['cases'])} texts ({len(harvested)} harvested "
        f"+ {len(ADVERSARIAL)} adversarial), {entities} entities, "
        f"from {gold['model']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
