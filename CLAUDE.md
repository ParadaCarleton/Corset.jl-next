# Corset

Rewrite in progress. Legacy code in src/ is idea source only; fix legacy bugs only as stopgap.
Design: docs/design/rules-rewrite.html. Read it before changing architecture or checks.
Footgun, family, check sections are generated: edit docs/design/build_footguns.py, run it.
Footgun IDs are stable; never reuse removed ID. Old rule names live only in rules-rewrite-history.md.
When unsure, do what Rust and Clippy do.

## Check contract

Check is pure function: facts in, findings out. Check imports only Corset.Facts.
Check never parses, lowers, loads or infers. Missing information: add fact to its analysis.
Every finding: primary span, labeled cause spans, one-line reason, fix with tier.
Every check: UI snapshot test with positive, negative and fix case.

## Scope

Never read or run package tests. Never analyze dependency code.
Support only latest Julia release.
Analysis gaps never become findings; coverage line reports them.
