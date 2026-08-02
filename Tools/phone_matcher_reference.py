#!/usr/bin/env python3
"""Record libphonenumber's PhoneNumberMatcher output as a differential oracle.

Every text is matched under every region and **every leniency**, including
STRICT_GROUPING (2) and EXACT_GROUPING (3). Those two verify the candidate's
digit grouping against a canonical format for the region, so they are where a
port is most likely to diverge -- and the two Presidio corpus cases that touch
them are nowhere near enough to call it verified.

The texts deliberately include the same number written several ways: as one
block, grouped canonically, grouped wrongly, with a national prefix, without
one, and with an extension. Grouping leniency is precisely the thing that
distinguishes those, so a corpus of well-formatted numbers would prove nothing.

Usage:
    python3 Tools/phone_matcher_reference.py --python <venv python> \\
        --out Tests/PresidioConformance/Fixtures/phone_matcher_gold.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys

REGIONS = ["US", "GB", "DE", "FR", "IL", "IN", "CA", "BR", "JP", "CN", "PH", "TR"]

CHILD = r'''
import json, sys
import phonenumbers

regions = json.loads(sys.argv[1])

TEXTS = [
    # Two numbers in one sentence, the second international.
    "My US number is (415) 555-0132, and my international one is +1 415 555 0132",
    "My US number is (415) 555-0132, and my international one is 91-415-555-0132",
    "My US number is (415) 555-0132, and my international one is +39 06 678 4343",
    # The same US number, grouped every way.
    "4155550132",
    "415-555-0132",
    "415 555 0132",
    "(415) 555-0132",
    "+1 415 555 0132",
    "+1-415-555-0132",
    "+14155550132",
    # Deliberately mis-grouped: the digits are right, the blocks are not.
    "41 5555 0132",
    "4155 550 132",
    "415-5550-132",
    "+1 41 5555 0132",
    # Extensions, which the grouping checks must not mistake for a group.
    "+1-415-555-0132 ext. 22",
    "(415) 555-0132 x22",
    "415-555-0132;ext=22",
    # National prefixes present and absent.
    "020 7946 0958",
    "+44 20 7946 0958",
    "02079460958",
    "09-7625400",
    "097625400",
    "0412 123 45 67",
    "4321234567",
    # Slashes: one is allowed, two are not unless the first split the code.
    "+1/415/555-0132",
    "+1/415 555 0132",
    "415/555/0132",
    # Dates and timestamps that must not be read as numbers.
    "2012-01-02 08:00",
    "3/10/2011",
    # Other regions written canonically and not.
    "+55 11 98456 5666",
    "+55 11984565666",
    "090-1234-5678",
    "09012345678",
    "13812345678",
    "+91 4155 550132",
    "+30 21 0 1234567",
    "+81 3 3239 0321",

    # --- Boundary characters. `_is_latin_letter` is Latin *blocks* only, so a
    # Cyrillic or Greek letter beside a number does NOT suppress the match,
    # while an accented Latin one does. Treating "any alphabetic scalar" as
    # Latin silently drops the first group.
    "abc8005001234",
    "8005001234def",
    "café4155550132",
    "4155550132café",
    "Привет4155550132",
    "4155550132Привет",
    "Ελλάδα4155550132",
    "4155550132日本",
    "日本4155550132",
    "naïve 415-555-0132",

    # `_is_invalid_punctuation_symbol` is '%' or Unicode category Sc, so every
    # currency sign suppresses a match and '@' does not.
    "%4155550132",
    "4155550132%",
    "$4155550132",
    "4155550132$",
    "£4155550132",
    "€4155550132",
    "¥4155550132",
    "@4155550132",
    "4155550132@",
    "user@4155550132.example",

    # --- Extension spellings from `_EXTN_PATTERN`, well beyond "ext"/"x"/"#".
    "415-555-0132 extension 22",
    "415-555-0132 extn 22",
    "415-555-0132 int 22",
    "415-555-0132 anexo 22",
    "415-555-0132 доб 22",
    "415-555-0132 ext: 22",
    "415-555-0132 ext. 22",
    "415-555-0132#22",
    "415-555-0132 ~22",
    "415-555-0132,,22",
    "415-555-0132;22",
    "415-555-0132 x22",
    "415-555-0132 X22",
    "+1 415-555-0132 ext 1234567",

    # --- Two numbers with no separator, which is what the inner-match search
    # is for. Upstream advances one character at a time, so it considers
    # overlapping candidates; a non-overlapping scan finds fewer.
    "4155550132 4155550199",
    "(415) 555-0132(415) 555-0199",
    "call 4155550132or4155550199 now",

    # --- Carrier codes, the two-'x' branch of `_contains_only_valid_x_chars`:
    # the digits after the marker must be the same number, checked by parsing
    # rather than by string comparison.
    "xx4155550132",
    "0xx4155550132",
    "415-555-0132 xx4155550132",
    "+1 415 555 0132 xx14155550132",
    "4155550132 xx4155550199",

    # --- Short and long numbers, to exercise the possible-length branches.
    "12",
    "1234",
    "415555013",
    "41555501320",
    "+1 4155550132000",
]

out = []
for text in TEXTS:
    for region in regions:
        for leniency in (0, 1, 2, 3):
            matches = list(
                phonenumbers.PhoneNumberMatcher(text, region, leniency=leniency)
            )
            out.append({
                "region": region,
                "text": text,
                "leniency": leniency,
                "matches": [
                    {"start": m.start, "end": m.end, "raw": m.raw_string}
                    for m in matches
                ],
            })

json.dump({
    "phonenumbers_version": phonenumbers.__version__,
    "cases": out,
}, sys.stdout, ensure_ascii=False)
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    import subprocess

    proc = subprocess.run(
        [args.python, "-c", CHILD, json.dumps(REGIONS)],
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

    cases = payload["cases"]
    by_leniency: dict[int, int] = {}
    for case in cases:
        by_leniency[case["leniency"]] = by_leniency.get(case["leniency"], 0) + len(case["matches"])
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  {len(cases)} cases, phonenumbers {payload['phonenumbers_version']}")
    for leniency in sorted(by_leniency):
        print(f"    leniency {leniency}: {by_leniency[leniency]} matches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
