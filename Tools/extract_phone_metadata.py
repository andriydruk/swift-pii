#!/usr/bin/env python3
"""Extract libphonenumber metadata for the regions Presidio's recognizers use.

`PhoneRecognizer` delegates entirely to `phonenumbers`, so there is no pattern
to lift — the behaviour lives in Google's metadata plus the matcher algorithm.
This pulls the metadata; the algorithm is ported separately.

Only the regions the recognizers actually configure are included. The full set
is ~250 regions and 0.5 MB of metadata; these twelve are a small fraction of
that, and the list is explicit so adding a region is a visible change.

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

# PhoneRecognizer.DEFAULT_SUPPORTED_REGIONS, plus JP/CN which the general test
# adds, plus PH and TR which have their own region-configured test suites, plus
# ZA for ZaMobileNumberRecognizer / ZaTelephoneNumberRecognizer.
REGIONS = ["US", "GB", "DE", "FR", "IL", "IN", "CA", "BR", "JP", "CN", "PH", "TR", "ZA"]

CHILD = r'''
import json, sys
import phonenumbers
from phonenumbers import phonemetadata

requested = json.loads(sys.argv[1])

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
matcher = {
    "pattern": _M._PATTERN.pattern,
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
