# Principles

Rules every design choice follows, and what Corset does not do.

- When unsure, do what Rust and Clippy do.
- Compute each expensive step once per run. Share output with every rule.
- Footguns are source of truth. Checks group footguns by analysis they read. User-facing group is metadata only.
- Give each finding confidence: `definite` (problem exists) or `possible` (problem not ruled out). One setting filters them.
- Map every finding back to source bytes. Fixers edit lossless syntax tree.
- Check is small query over shared facts. It never parses, lowers, loads or infers by itself.
- Every finding explains itself: cause spans, one-line reason, concrete fix. Rust compiler errors set bar.
- Cache findings on disk. Unchanged code is never analyzed twice, across restarts too.
- Keep linter process warm. Load target package once. Infer each package method once; every typed check shares result.
- Read typed IR from native compiler at lint time. Other linters (JET, fatou, LintApp.jl, ReLint.jl) serve only as test references and code sources.

## Non-goals

- Formatting: Runic or JuliaFormatter own it.
- Running package tests, or reading signatures from them.
- Analyzing dependency code, Base included. Code that macros expand into package counts as package code.
- Julia versions older than latest release.
- Security sandbox around package code. Corset loads code its user chose to lint.
- Version 1: language server; race and ownership analysis. Shape checks F68–F70 stay.
