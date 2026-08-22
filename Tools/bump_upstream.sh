#!/usr/bin/env bash
# Bump the upstream Presidio pin and regenerate everything derived from it.
#
#   Tools/bump_upstream.sh <ref> [nearest-release-tag]
#
# <ref> is a tag or commit sha. The policy is to land on release tags
# (upstream cuts them roughly monthly); a sha is for when the port needs a fix
# that has not been released yet, which is how the current pin came to be.
#
# What this does — the exact procedure of the first executed bump, frozen:
#
#   1. fetch the ref into .upstream-presidio
#   2. regenerate every checkout-derived artifact in place
#   3. refresh the conf fixtures that are verbatim upstream copies
#   4. write Tools/upstream.json
#   5. print the diff; YOU run `swift test` and port whatever it surfaces
#
# A changed corpus case with an unchanged catalogue means upstream fixed a test;
# a changed catalogue means behaviour moved and the tests will say whether the
# Swift side already absorbs it (most changes are data-driven and need no code).
#
# Deliberately NOT touched, with reasons:
#   - ner/parser/tagger/language golds, attribute ruler: spaCy-derived; a
#     Presidio bump cannot move them.
#   - analyzer_reference / batch_reference / registry_gold: recorded from a
#     *running* Python Presidio. Re-record only when the diff touches engine
#     behaviour (Tools/analyzer_reference.py etc., needs presidio installed).
#   - computed_cases.json: needs a python that can IMPORT presidio_analyzer
#     (venv with Tools/requirements.txt + `pip install --no-deps
#     .upstream-presidio/presidio-analyzer` + tldextract + pytest). Regenerated
#     here only when such a python is supplied via BUMP_PYTHON; otherwise the
#     lint will name it stale, which is the reminder.
set -euo pipefail
cd "$(dirname "$0")/.."

REF="${1:?usage: Tools/bump_upstream.sh <ref> [nearest-release-tag]}"
RELEASE="${2:-}"
REPO=$(python3 -c "import json; print(json.load(open('Tools/upstream.json'))['repo'])")

echo "== fetching $REPO @ $REF"
rm -rf .upstream-presidio
git init -q .upstream-presidio
git -C .upstream-presidio remote add origin "https://github.com/$REPO.git"
git -C .upstream-presidio fetch -q --depth 1 origin "$REF"
git -C .upstream-presidio checkout -q FETCH_HEAD
SHA=$(git -C .upstream-presidio rev-parse HEAD)
echo "   resolved to $SHA"

if [[ -z "$RELEASE" ]]; then
  RELEASE=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null || true)
  [[ -n "$RELEASE" ]] && echo "   nearest release (from gh): $RELEASE" \
    || { RELEASE=$(python3 -c "import json; print(json.load(open('Tools/upstream.json'))['nearest_release'])"); echo "   gh unavailable; keeping nearest_release=$RELEASE"; }
fi

echo "== regenerating checkout-derived artifacts"
python3 Tools/extract_fixtures.py --presidio .upstream-presidio \
  --out Tests/PresidioConformance/Fixtures/recognizer_cases.json
python3 Tools/extract_operation_cases.py --presidio .upstream-presidio \
  --out Tests/PresidioConformance/Fixtures/operation_cases.json
python3 Tools/extract_patterns.py --presidio .upstream-presidio \
  --out Sources/PresidioRecognizers/Resources/recognizers.json
python3 Tools/extract_registry_config.py --presidio .upstream-presidio \
  --out Sources/PresidioEngine/Resources/registry_config.json
python3 Tools/extract_iban.py --presidio .upstream-presidio \
  --out Sources/PresidioRecognizers/Resources/iban_countries.json
curl -sSL -o /tmp/bump_psl.dat https://publicsuffix.org/list/public_suffix_list.dat
# --psl-out goes to /tmp, NOT to the committed public_suffix_list.json: the
# PSL is a live download with its own upstream and its own churn, and a
# Presidio bump must not smuggle a PSL refresh in with it. Refreshing the PSL
# is a separate, deliberate act. (recognizer_data.json does not currently
# embed PSL content — if it ever diffs here while the catalogue did not
# change, suspect PSL churn before suspecting Presidio.)
python3 Tools/extract_recognizer_data.py --presidio .upstream-presidio \
  --psl /tmp/bump_psl.dat \
  --out Sources/PresidioRecognizers/Resources/recognizer_data.json \
  --psl-out /tmp/bump_psl_out.json

if [[ -n "${BUMP_PYTHON:-}" ]]; then
  echo "== regenerating computed fixtures with $BUMP_PYTHON"
  python3 Tools/extract_computed_fixtures.py --presidio .upstream-presidio \
    --python "$BUMP_PYTHON" --out Tests/PresidioConformance/Fixtures/computed_cases.json
else
  echo "== SKIPPING computed_cases.json (set BUMP_PYTHON to a python that imports presidio_analyzer)"
fi

echo "== refreshing conf fixtures that are verbatim upstream copies"
python3 - <<'PY'
import os, shutil
ours = "Tests/PresidioConformance/Fixtures/conf"
sources = [".upstream-presidio/presidio-analyzer/tests/conf",
           ".upstream-presidio/presidio-analyzer/presidio_analyzer/conf"]
upstream = {}
for d in sources:
    for f in sorted(os.listdir(d)):
        p = os.path.join(d, f)
        if os.path.isfile(p):
            upstream.setdefault(f, p)
refreshed = 0
for f in sorted(os.listdir(ours)):
    op = os.path.join(ours, f)
    if not os.path.isfile(op):
        continue
    # Fixture names sometimes carry a test_ prefix upstream lacks, or vice
    # versa; a fixture matching no upstream name is locally written and stays.
    for cand in (f, f.removeprefix("test_"), "test_" + f):
        src = upstream.get(cand)
        if src:
            break
    if src and open(op, "rb").read() != open(src, "rb").read():
        shutil.copyfile(src, op)
        refreshed += 1
        print(f"   refreshed {f}  <-  {src.split('presidio-analyzer/')[-1]}")
print(f"   {refreshed} conf fixture(s) refreshed")
PY

echo "== writing Tools/upstream.json"
python3 - "$SHA" "$RELEASE" <<'PY'
import json, sys, subprocess
d = json.load(open('Tools/upstream.json'))
d['commit'] = sys.argv[1]
d['nearest_release'] = sys.argv[2]
date = subprocess.run(['git','-C','.upstream-presidio','log','-1','--format=%cs'],
                      capture_output=True, text=True).stdout.strip()
d['description'] = f"{sys.argv[2]}" + ("" if sys.argv[1].startswith(sys.argv[2]) else f" era, exact commit of {date}")
json.dump(d, open('Tools/upstream.json','w'), indent=2)
print(f"   pinned {sys.argv[1][:12]} (nearest release {sys.argv[2]})")
PY

echo "== what changed"
git diff --stat
echo
echo "Now: ./Tools/check_portability.sh && swift test -c release"
echo "A red test here is the point — it is the ported behaviour that moved."
