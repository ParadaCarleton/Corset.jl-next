# Principles

Principles behind every design choice, and what Corset does not do.

- When unsure, do what Rust and Clippy do.
- Every decision is revisable. Evidence from corpus runs and users outranks earlier reasoning; see design reviews in `plan.md`.
- Compute each expensive step once per run. Share output with every rule.
- Footguns are source of truth. Rules group footguns by analysis they read. User-facing group is metadata only.
- Give each finding confidence: `definite` (problem exists) or `possible` (compiler cannot resolve doubt either). One setting filters them. Corset blind spots go to coverage line only (`findings.md`).
- Map every finding back to source bytes. Fixers edit lossless syntax tree.
- Rule is small query over shared facts. Analysis stages compute every fact once per run; rule only reads them.
- Each fact has one producer. Rule never guesses later-stage fact (type, mutability, effect, ADT variant) from syntax; it waits for that stage.
- Rule belongs to last stage its findings need. One rule never mixes `syntax` footguns with footguns of later stages.
- Fixer may read later stages when they ran. Otherwise its fix is `manual`.
- Every finding explains itself: cause spans, one-line reason, concrete fix. Rust compiler errors set bar.
- Cache findings on disk. Unchanged code is never analyzed twice, across restarts too.
- Keep linter process warm. Load target package once. Infer each package method once; every typed rule shares result.
- Read typed IR from native compiler at lint time. Other linters (JET, fatou, LintApp.jl, ReLint.jl) serve only as test references and code sources.

## Non-goals

- Formatting: Runic or JuliaFormatter own it.
- Relying on package tests or precompile workloads. Facts come from source, type annotations, loaded module and inference. Package without tests or workloads gets full analysis. Code that ran before Corset changes speed only, never findings.
- Findings in dependency code, Base included. Analysis reads dependency code freely (callee summaries, inference); only findings stay inside package. Code that package macros write counts as package code; code that other packages' macros write does not.
- Julia versions older than latest release.
- Security sandbox around package code. Corset loads code its user chose to lint.
- Version 1: language server; race and ownership analysis. Shape rules F68–F70 stay.
