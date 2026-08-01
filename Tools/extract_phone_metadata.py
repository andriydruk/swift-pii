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
# adds, plus PH and TR which have their own region-configured test suites.
REGIONS = ["US", "GB", "DE", "FR", "IL", "IN", "CA", "BR", "JP", "CN", "PH", "TR"]

CHILD = r'''
import json, sys
import phonenumbers
from phonenumbers import phonemetadata

regions = json.loads(sys.argv[1])

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
by_code = {}
for region in regions:
    m = phonemetadata.PhoneMetadata.metadata_for_region(region)
    if m is None:
        continue
    by_code.setdefault(str(m.country_code), []).append(region)
for code, members in by_code.items():
    members.sort(key=lambda r: not phonemetadata.PhoneMetadata.metadata_for_region(r).main_country_for_code)

json.dump({
    "phonenumbers_version": phonenumbers.__version__,
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
