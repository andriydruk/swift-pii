# 0002 — Concurrency model, and validating the guard that checks it

Status: accepted (M5)

## Context

`AnalyzerEngine` is a `Sendable` struct, so nothing stops a caller building one
and sharing it across tasks — and they should, because construction costs ~20 ms
while `analyze` costs ~3 ms. That makes thread safety a property of every type
reachable from the engine, not an optional extra.

M4 added two NLP engine wrappers and marked them `@unchecked Sendable` without
auditing what they wrapped. That was wrong.

## What was actually shared

`SpacyTokenizer` has two kinds of mutable state:

1. A memoization cache (`[String: [(String, String?)]]`) written on every cache
   miss. Measured worth: **4.3×** on repeated text, so removing it was not an
   option.
2. Three derived special-case tables built with `lazy var`. Lazy initialization
   is *itself* a data race on a shared instance — two tasks can enter the
   initializer concurrently.

`NERModel`'s weights are `var`, but only because the msgpack decode assigns them
in a loop; they are written during `init` and read-only afterwards, and
inference allocates its scratch per call.

## Decision

- The cache stays, guarded by an `NSLock`. The critical sections are two
  dictionary operations; `tokenizeSpan` runs *outside* the lock, so two tasks
  may duplicate work for the same span rather than serializing on it. Measured
  cost on the warm path: none (0.098 s → 0.096 s over 312k tokens).
- The three lazy tables are built eagerly in `init`.
- Every remaining `@unchecked Sendable` carries its justification at the
  declaration. If it cannot be justified in a sentence, it is not safe.

## Validating the guard

ThreadSanitizer cannot load on this project's macOS dev host — Xcode's sanitizer
dylib fails the platform code-signature policy — so the race check runs as a
Linux CI job.

**The first version of that job was a placebo, and the only reason we know is
that we tried to break it.** The concurrency test computed its expected results
serially and then had eight tasks re-analyze the same five texts. That warmed
the cache, so the concurrent phase only ever *read* it and TSan saw nothing.

Verified by pushing a branch with the lock removed:

| harness | lock removed | TSan verdict |
|---|---|---|
| original (fixed corpus, warmed) | yes | **passed** — no race reported |
| current (novel text per task) | yes | **failed** — `Swift access race` in `SpacyTokenizer.emit` |
| current | no | passed |

The test now generates text no other task has seen, so cache writes and reads
collide. CI runs on `ci/**` branches specifically so this kind of check can be
repeated: a sanitizer job that has only ever seen correct code proves nothing
about whether it would catch the bug.

## Consequences

- One engine can be shared across tasks; that is the intended usage.
- `SpacyTokenizer`, `SpacyNER` and both NLP engine wrappers are `@unchecked
  Sendable` with audited justifications rather than assumed ones.
- Any future addition of shared mutable state has a test that will actually
  fail — which was not true before.
