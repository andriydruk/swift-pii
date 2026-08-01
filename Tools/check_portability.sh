#!/usr/bin/env bash
#
# Portability lint.
#
# macOS is the first supported platform, but the source must stay portable so
# Android and Windows are a port rather than a rewrite. The cheapest way to
# guarantee that is to fail the build the moment an Apple-only dependency
# appears -- retrofitting portability later is expensive, catching it the week
# it lands is free.
#
# Run:  ./Tools/check_portability.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

status=0

fail() {
    printf '\033[31mFAIL\033[0m %s\n' "$1"
    status=1
}

pass() {
    printf '\033[32m ok \033[0m %s\n' "$1"
}

# ---------------------------------------------------------------------------
# 1. No Apple closed-source frameworks.
# ---------------------------------------------------------------------------
# These have no implementation outside Darwin, so importing one makes the
# package permanently macOS/iOS-only. NaturalLanguage and CoreML in particular
# are what the design deliberately replaced with the ported spaCy pipeline.
BANNED_FRAMEWORKS=(
    NaturalLanguage CoreML Vision VisionKit DataDetection
    CryptoKit CommonCrypto Accelerate TabularData
    Metal MetalPerformanceShaders CoreImage
    AppKit UIKit SwiftUI CoreGraphics QuartzCore
)

for fw in "${BANNED_FRAMEWORKS[@]}"; do
    hits=$(grep -rnE "^[[:space:]]*(@[a-zA-Z_]+[[:space:]]+)?import[[:space:]]+${fw}\b" \
        --include='*.swift' Sources Tests 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        fail "banned Apple framework '${fw}':"
        printf '       %s\n' "$hits"
    fi
done
[[ $status -eq 0 ]] && pass "no Apple closed-source framework imports"

# ---------------------------------------------------------------------------
# 2. Foundation, never FoundationEssentials.
# ---------------------------------------------------------------------------
# canImport(FoundationEssentials) is FALSE on Darwin with the current toolchain,
# so importing it "for portability" is precisely what breaks the macOS build.
# On Linux and Windows, corelibs-foundation re-exports it under Foundation.
fe_hits=$(grep -rnE "^[[:space:]]*import[[:space:]]+FoundationEssentials\b" \
    --include='*.swift' Sources Tests 2>/dev/null || true)
if [[ -n "$fe_hits" ]]; then
    fail "import FoundationEssentials (use 'import Foundation'):"
    printf '       %s\n' "$fe_hits"
else
    pass "no FoundationEssentials imports"
fi

# ---------------------------------------------------------------------------
# 3. The core layers stay Foundation-free.
# ---------------------------------------------------------------------------
# The offset model, the regex engine and the anonymizer are pure stdlib --
# including the anonymizer's own SHA-2. Keeping them that way means the
# innermost layers have no ICU or platform dependency at all: valuable for WASM
# and Embedded, and a useful forcing function against creeping NSString habits
# in index arithmetic.
for target in PresidioCore PresidioRegex PresidioAnonymizer; do
    [[ -d "Sources/$target" ]] || continue
    hits=$(grep -rnE "^[[:space:]]*import[[:space:]]+Foundation\b" \
        --include='*.swift' "Sources/$target" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        fail "$target must not import Foundation:"
        printf '       %s\n' "$hits"
    else
        pass "$target is Foundation-free"
    fi
done

# ---------------------------------------------------------------------------
# 3a. swift-crypto stays confined to one target.
# ---------------------------------------------------------------------------
# It vendors BoringSSL, which does not build everywhere (WASM notably). Keeping
# it behind PresidioAnonymizerCrypto means detection and the anonymizer core
# remain buildable on every target; letting it leak would silently narrow the
# platform matrix.
crypto_hits=$(grep -rlnE "^[[:space:]]*import[[:space:]]+(Crypto|_CryptoExtras)\b" \
    --include='*.swift' Sources 2>/dev/null | grep -v '^Sources/PresidioAnonymizerCrypto/' || true)
if [[ -n "$crypto_hits" ]]; then
    fail "swift-crypto imported outside PresidioAnonymizerCrypto:"
    printf '       %s\n' "$crypto_hits"
else
    pass "swift-crypto confined to PresidioAnonymizerCrypto"
fi

# 3b. Yams stays confined to one target.
# ---------------------------------------------------------------------------
# Yams vendors libyaml's C source, which is portable, but reproducing Presidio's
# *defaults* needs no YAML parser at all -- the default config is resolved to
# JSON at build time. Keeping Yams behind PresidioEngineYAML means callers who
# never read a config file never link a YAML parser.
yaml_hits=$(grep -rlnE "^[[:space:]]*import[[:space:]]+Yams\b" \
    --include='*.swift' Sources 2>/dev/null | grep -v '^Sources/PresidioEngineYAML/' || true)
if [[ -n "$yaml_hits" ]]; then
    fail "Yams imported outside PresidioEngineYAML:"
    printf '       %s\n' "$yaml_hits"
else
    pass "Yams confined to PresidioEngineYAML"
fi

# ---------------------------------------------------------------------------
# 3b. Unicode tables must not be hand-edited.
# ---------------------------------------------------------------------------
# They are generated from Python's `regex` module and pin the Unicode version
# that \b/\w/\d behaviour depends on. A hand edit silently changes detection
# results on every one of the 131 patterns that use \b.
TABLES=Sources/PresidioRegex/UnicodeTables.swift
if [[ -f "$TABLES" ]]; then
    if ! head -1 "$TABLES" | grep -q "Generated by Tools/unicode_classes_python.py"; then
        fail "$TABLES lost its generated-file header"
    else
        pass "Unicode tables are generated (not hand-edited)"
    fi
fi

# ---------------------------------------------------------------------------
# 4. The conformance corpus is present and non-trivial.
# ---------------------------------------------------------------------------
# A missing or truncated corpus makes the whole suite pass vacuously, which is
# the failure mode that matters most: upstream's skip_by_engine fixture hides
# absent models the same way.
CORPUS=Tests/PresidioConformance/Fixtures/recognizer_cases.json
if [[ ! -f "$CORPUS" ]]; then
    fail "missing conformance corpus: $CORPUS (run Tools/extract_fixtures.py)"
else
    cases=$(python3 -c "import json,sys; d=json.load(open('$CORPUS')); print(sum(len(t['cases']) for t in d['tables']))" 2>/dev/null || echo 0)
    if [[ "$cases" -lt 1600 ]]; then
        fail "conformance corpus has only ${cases} cases (expected >= 1600)"
    else
        pass "conformance corpus: ${cases} cases"
    fi
fi

# The registry configuration decides which recognizers a default engine loads.
# Without it the engine would load the whole catalogue and report entities
# Presidio never would -- which reads as a wall of false positives, not as a
# missing file.
REGCONF=Sources/PresidioEngine/Resources/registry_config.json
if [[ ! -f "$REGCONF" ]]; then
    fail "missing registry config: $REGCONF (run Tools/extract_registry_config.py)"
else
    enabled=$(python3 -c "import json; d=json.load(open('$REGCONF')); print(sum(1 for e in d['recognizers'] if e['enabled'] and any(l['language']=='en' for l in e['languages'])))" 2>/dev/null || echo 0)
    if [[ "$enabled" -ne 17 ]]; then
        fail "registry config enables ${enabled} English recognizers (expected 17)"
    else
        pass "registry config: ${enabled} English recognizers enabled"
    fi
fi

exit $status
