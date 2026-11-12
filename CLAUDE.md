# Corset

Rewrite in progress; rewrite lives in src/. Legacy code lives in lib/CorsetLegacy: idea source only; fix legacy bugs only as stopgap. Delete legacy feature once rewrite replaces it.
Design: docs/design/README.md indexes parts. Read only parts task needs before changing architecture or checks.
Edit design parts (*.md, *.toml), then run `uv run docs/design/build.py`. Never hand-edit rules-rewrite.html.
Footgun IDs are stable; never reuse removed ID. Old rule names live only in rules-rewrite-history.md.
When unsure, do what Rust and Clippy do.
Workspaces live in .worktrees/<name> inside repo (git-ignored); never in sibling directories.

## Check contract

Check is pure function: facts in, findings out. Check imports only Corset.Facts.
Check never parses, lowers, loads or infers. Missing information: add fact to its analysis.
Every finding: primary span, labeled cause spans, one-line reason, fix with tier.
Every check: UI snapshot test with positive, negative and fix case.

## Scope

Never read or run package tests. Report findings only in package code; analysis may read dependency code, Base included.
Support only latest Julia release.
Analysis gaps never become findings; coverage line reports them.
