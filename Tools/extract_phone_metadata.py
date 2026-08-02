#!/usr/bin/env python3
"""Extract libphonenumber metadata for the regions Presidio's recognizers use.

`PhoneRecognizer` delegates entirely to `phonenumbers`, so there is no pattern
to lift — the behaviour lives in Google's metadata plus the matcher algorithm.
This pulls the metadata; the algorithm is ported separately.

All ~245 regions are included. An earlier version took only the regions the
recognizers configure, which conflated *scanning* with *validation*: a number
carrying its own country code is parsed regardless of the configured regions,
and without that region's metadata it cannot be validated, so it is dropped.

Usage:
    python3 Tools/extract_phone_metadata.py --python <venv python> \\
        --out Sources/PresidioRecognizers/Resources/phone_metadata.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

# Every region libphonenumber knows, not just the ones the recognizers
# configure. Scanning is per configured region, but *validation* is not: a
# number written "+39 06 678 4343" is parsed from its own country code, and
# without Italian metadata it cannot be validated and is silently dropped.
# Restricting the extract to 13 regions therefore did not save a lookup, it
# lost real numbers.
#
# Cost measured before committing to it: 121 KB -> 526 KB of bundled JSON, and
# no measurable change to engine throughput or construction time, because the
# metadata is decoded once, lazily, and descriptor patterns compile on demand.
REGIONS = ["__ALL__"]

CHILD = r'''
import json, sys
import phonenumbers
from phonenumbers import phonemetadata

requested = json.loads(sys.argv[1])
if requested == ["__ALL__"]:
    from phonenumbers.phonenumberutil import SUPPORTED_REGIONS
    requested = sorted(SUPPORTED_REGIONS)

# Every region sharing a country code with a requested one must be included.
# region_code_for_number returns a single-region code UNCONDITIONALLY and only
# disambiguates when a code has several regions -- so a truncated list would
# turn +44 (GB, GG, IM, JE) into an unconditional "GB" and diverge.
from phonenumbers.phonenumberutil import COUNTRY_CODE_TO_REGION_CODE
codes = set()
for region in requested:
    m = phonemetadata.PhoneMetadata.metadata_for_region(region)
    if m is not None:
        codes.add(m.country_code)
regions = []
for code in sorted(codes):
    for region in COUNTRY_CODE_TO_REGION_CODE.get(code, []):
        if region not in regions:
            regions.append(region)

def desc(d):
    if d is None:
        return None
    return {
        "national_number_pattern": d.national_number_pattern,
        "possible_length": list(d.possible_length or []),
        "possible_length_local_only": list(d.possible_length_local_only or []),
    }

def fmt(f):
    return {
        "pattern": f.pattern,
        "format": f.format,
        "leading_digits_pattern": list(f.leading_digits_pattern or []),
        "national_prefix_formatting_rule": f.national_prefix_formatting_rule,
        "national_prefix_optional_when_formatting": bool(
            f.national_prefix_optional_when_formatting
        ),
    }

out = {}
for region in regions:
    m = phonemetadata.PhoneMetadata.metadata_for_region(region)
    if m is None:
        continue
    out[region] = {
        "country_code": m.country_code,
        "national_prefix": m.national_prefix,
        "national_prefix_for_parsing": m.national_prefix_for_parsing,
        "national_prefix_transform_rule": m.national_prefix_transform_rule,
        "leading_digits": m.leading_digits,
        "main_country_for_code": bool(m.main_country_for_code),
        "same_mobile_and_fixed_line_pattern": bool(m.same_mobile_and_fixed_line_pattern),
        "general_desc": desc(m.general_desc),
        "fixed_line": desc(m.fixed_line),
        "mobile": desc(m.mobile),
        "toll_free": desc(m.toll_free),
        "premium_rate": desc(m.premium_rate),
        "shared_cost": desc(m.shared_cost),
        "personal_number": desc(m.personal_number),
        "voip": desc(m.voip),
        "pager": desc(m.pager),
        "uan": desc(m.uan),
        "voicemail": desc(m.voicemail),
        "number_format": [fmt(f) for f in (m.number_format or [])],
        "intl_number_format": [fmt(f) for f in (m.intl_number_format or [])],
    }

# Which regions share each country code, in the order libphonenumber tries them.
# +1 covers both US and CA, and region_code_for_number has to pick.
# Preserve libphonenumber's own ordering: it is what decides which region wins.
by_code = {}
for code in sorted(codes):
    members = [r for r in COUNTRY_CODE_TO_REGION_CODE.get(code, []) if r in out]
    if members:
        by_code[str(code)] = members

# The matcher's own regexes. These are built from character-class constants at
# import time, so they are lifted as compiled strings rather than reconstructed.
import phonenumbers.phonenumbermatcher as _M
# Alternate number formats, keyed by country calling code. STRICT_GROUPING and
# EXACT_GROUPING retry against these when the canonical format does not match,
# so without them the port would be stricter than upstream.
alt_formats = {}
for code, formats in _M._ALT_NUMBER_FORMATS.items():
    alt_formats[str(code)] = [fmt(f) for f in formats]

matcher = {
    "pattern": _M._PATTERN.pattern,
    # Runs of the separator characters libphonenumber allows inside a number.
    # Used to turn a formatted number into its digit groups.
    "separator": phonenumbers.phonenumberutil._SEPARATOR_PATTERN.pattern,
    # Extension markers. Far richer than "ext"/"x"/"#": it covers extn, int,
    # anexo, доб, full-width forms, ~, ;, ,, and a bare trailing #.
    "extn": phonenumbers.phonenumberutil._EXTN_PATTERN.pattern,
    # What counts as "could be a phone number at all", used to decide whether
    # the text before an extension marker is worth keeping.
    "valid_phone_number": phonenumbers.phonenumberutil._VALID_PHONE_NUMBER_PATTERN.pattern,
    "min_length_for_nsn": phonenumbers.phonenumberutil._MIN_LENGTH_FOR_NSN,
    "matching_brackets": _M._MATCHING_BRACKETS.pattern,
    "pub_pages": _M._PUB_PAGES.pattern,
    "slash_dates": _M._SLASH_SEPARATED_DATES.pattern,
    "time_stamps": _M._TIME_STAMPS.pattern,
    "time_stamps_suffix": _M._TIME_STAMPS_SUFFIX.pattern,
    "lead_class": _M._LEAD_CLASS,
    "unwanted_end_chars": _M._UNWANTED_END_CHAR_PATTERN.pattern,
    "inner_matches": [p.pattern for p in _M._INNER_MATCHES],
}

json.dump({
    "phonenumbers_version": phonenumbers.__version__,
    "matcher": matcher,
    "regions": out,
    "regions_by_country_code": by_code,
    "alt_number_formats": alt_formats,
}, sys.stdout, ensure_ascii=False)
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proc = subprocess.run(
        [args.python, "-c", CHILD, json.dumps(REGIONS)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        print(proc.stderr, file=sys.stderr)
        return 2

    payload = json.loads(proc.stdout)
    payload["schema_version"] = 1

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")

    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  phonenumbers {payload['phonenumbers_version']}")
    print(f"  regions {len(payload['regions'])}: {', '.join(sorted(payload['regions']))}")
    print(f"  country codes {sorted(payload['regions_by_country_code'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
