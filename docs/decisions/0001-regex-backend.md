# ADR 0001 — Regex backend

**Status:** accepted
**Date:** 2026-07-31
**Gates:** PLAN.md §5 decision 1, M1

## Decision

**Use a pure-Swift regex engine driven by Unicode character-class tables generated from Python's `regex` module and shipped as package data.**

Rejected: Swift Regex (`_StringProcessing`), `NSRegularExpression` (ICU), and PCRE2 as the primary backend.

## Context

Presidio does `import regex as re` — the third-party module, not stdlib `re`
(`pattern.py:4`, `pattern_recognizer.py:6`, `analyzer_engine.py:8`,
`iban_recognizer.py:6`). Its `\w` follows UTS#18.

**131 of 155 Presidio patterns (85%) contain `\b`**, and `\b` is *defined in
terms of* `\w`. So the word-character set is not a detail — it decides which PII
is found. `\d` appears in 112 patterns.

## Evidence

Measured over all 1,112,064 non-surrogate codepoints. Reference: `regex`
2.5.148. Backends: macOS 26.5.2, Swift 6.2.4.
Reproduce with `Tools/unicode_classes_python.py` then `Tools/unicode_classes_swift.swift`.

### `\w` (Python: 144,667 codepoints)

| Backend | Extra | Missing | Verdict |
|---|---:|---:|---|
| NSRegularExpression (ICU) | 4,773 | **0** | definition matches; skew only |
| Swift Regex (default) | 5,622 | **1,147** | structurally different |
| Swift Regex (`.unicodeScalar`) | 4,697 | **1,897** | worse |

Swift Regex's missing set is the damaging one: **Mn 1,093** (combining marks —
so `\b` breaks around any accented text), Mc 30, Me 13, Pc 9, and **Cf 2**
(ZWJ/ZWNJ). Under `.unicodeScalar` it additionally drops **Nd 750**, including
Arabic-Indic digits U+0660–U+0669.

### `\d` (Python: 760 codepoints)

| Backend | Extra | Missing |
|---|---:|---:|
| NSRegularExpression (ICU) | 10 | 0 |
| Swift Regex (either mode) | **1,263** | 0 |

Swift Regex's extras are **No 915** (superscripts `²³¹`, fractions `½`), **Nl 239**
(Roman numerals, circled digits), Lo 99. This is why `\b\d{6,14}\b` matches
`①②③④⑤⑥⑦⑧⑨⑩` and `½½½½½½½½½½` — a standing false-positive generator across
112 patterns.

### `\s` — all three backends identical to Python.

### The ICU divergence is version skew, not a definition difference

Every sampled ICU "extra" (U+088F, U+0C5C, U+A7CE, U+11DE0, U+16FF4, U+F870 …)
is **unassigned in Unicode 13.0.0** — the version Python's data uses — and
assigned in the newer Unicode that macOS 26's ICU ships. ICU implements the same
UTS#18 definition as `regex`; only the data vintage differs.

This is the load-bearing finding, and it *disqualifies ICU rather than
vindicating it*: because the difference is data version, **`\w` membership
varies by platform and OS release.** Android's bundled ICU, Windows' ICU, and
macOS's ICU are all different versions. No amount of pattern rewriting fixes
that. A library that must behave identically on Android, macOS and Windows
cannot source its character classes from the host's ICU.

Note this also refines, rather than contradicts, the earlier finding that PCRE2
diverges structurally. PCRE2 with `PCRE2_UCP` defines `\w` as
`\p{L}+\p{N}+\p{Mn}+\p{Pc}`, which genuinely differs from UTS#18 (it drops Mc,
Me, So and Join_Control while adding No and Nl). ICU does not have that problem.
Both are rejected, for different reasons.

## Consequences

**Good**

- Byte-identical `\b`/`\w`/`\d` behaviour on every target, by construction.
- The Unicode version is pinned, reviewable data in the repo, and upgrading it
  is a deliberate, diffable change rather than a silent OS-update behaviour shift.
- No Foundation or ICU dependency in the matching path, so it satisfies the
  no-Apple-closed-source constraint without needing the "Foundation is morally
  open source" argument.
- Prototype already exists and was measured Python-table-exact
  ([`prototypes/pure-swift-regex-Engine.swift`](../../prototypes/pure-swift-regex-Engine.swift), 486 lines).

**Bad**

- **Slower than Python.** Measured on the real workload (all 155 patterns over
  the 1,571-text / 30,896-scalar conformance corpus, release build, M4 Max,
  best of 5 via `swift run -c release presidio-bench`):

  | | full sweep | relative |
  |---|---:|---:|
  | Python `regex` (C) | 0.093 s | 1.0× |
  | this engine | 0.514 s | **5.5× slower** |

  Compilation is 28 ms for all 155 patterns (0.18 ms each), so it is matching,
  not parsing, that costs. Throughput is 58.7 KB/s of corpus through the full
  155-pattern set — sweeping a 10 KB document costs roughly 0.17 s.

  This is the price of the trade and it should be stated plainly rather than
  buried: we are slower than the Python implementation we are replacing. It is
  acceptable for M1 because correctness is the gate and the absolute numbers are
  small, but it is the primary optimization target for M5. The prototype
  measured 2.7× faster than Swift Regex and ~5× slower than PCRE2, which is
  consistent with this.
- We own a regex engine. Mitigated by the feature census: Presidio needs a
  *small* subset — 0 named groups, 0 atomic groups, 0 possessive quantifiers,
  0 conditionals, 0 `\p{...}`, 0 `\B`, and only fixed-width lookbehind
  (19 patterns, all single-character negative).

**Resolved (2026-08-01): the matcher is now a bytecode VM.**

The original continuation-passing matcher recursed once per repetition
iteration, so depth grew with the *input* length at ~2.7 KB per iteration:

| Pattern | Stack | Died at |
|---|---|---|
| `a+` | 8 MB (main thread) | ~2–4k characters |
| spaCy infix | 512 KB (Task / test runner) | ~400 characters |

512 KB is what Swift concurrency's cooperative pool and swift-testing's runner
hand out, so this was a crash-on-ordinary-input defect for any caller using a
`Task` — a denial of service for a library that scans arbitrary documents.

`Program.swift` compiles the AST to instructions and `VM.swift` runs them with
an explicit heap-allocated backtrack stack and an undo log for captures. Depth
is now bounded by memory. The only recursion left is one level per *nested
lookaround*, which is a property of the pattern (1–2) and never of the input.

Measured after the change:

| | Before | After |
|---|---|---|
| `a+` on 8 MB stack | ~2–4k chars | **500,000 chars** |
| `a+` on 512 KB stack | ~400 chars | **100,000 chars** |
| 155-pattern sweep | 0.507 s | **0.454 s** |
| Throughput | 59.5 KB/s | **65.8 KB/s** |

So it is both unbounded and ~10% faster. Three things mattered for the speed:
recursing on `self` for lookarounds rather than copying the VM struct (which
duplicated the program, the input and every slot on each evaluation), an ASCII
fast path for case folding (`Fold.variants` built a String, a Set and an Array
per call), and hoisting the VM out of the scan loop so the slot array is not
reallocated at every start position.

Bounded repeats are expanded rather than counted: across every pattern this
package compiles, the largest upper bound is 63 and total expansion is ~1,987
instructions, which is cheaper than counter machinery.

Semantics were held to the differential corpus throughout — 240,250 pattern
comparisons plus capture-group spans, 63,453 tokens, and the NER parity suite.
Three deviations from textbook regex that the old matcher had are reproduced
deliberately and marked in the source: `$` matching before a trailing newline
without MULTILINE, captures persisting out of a successful positive lookaround,
and a zero-width mandatory repetition failing its path rather than being
accepted.

The large-stack test harness this previously required has been deleted.

Relative to Python we are now 4.9× slower (0.454 s vs 0.093 s), improved from
5.5×.

**Deferred**

- PCRE2 stays viable as an opt-in fast path *if* profiling demands it, but only
  behind the same table substitution, and it must pass the differential corpus.
  Do not adopt it on performance grounds alone.

## Follow-up

- ~~Ship the generated tables and assert Swift membership equals Python exactly.~~
  Done — `UnicodeTables.swift`, verified across all 1,112,064 codepoints.
- ~~Benchmark the engine on the real 155-pattern corpus before M1 closes.~~
  Done — see above.
- Re-run this differential in CI whenever the `regex` module version changes.
- ~~Convert the matcher to an explicit stack.~~ Done — see above.
- **M5 optimization targets**, in expected order of payoff: a literal-prefix
  index so a text is not swept once per pattern (currently 155 independent
  passes); memoization of the backtracking matcher; and making `PureRegex`
  `Sendable` so patterns can be shared and swept concurrently.
- Revisit PCRE2-with-table-substitution only if M5 leaves the engine short of
  budget. Correctness stays the gate.
