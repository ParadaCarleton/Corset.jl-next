# Findings

How findings are graded, filtered, configured, shown and fixed.

Four groups: `correctness`, `performance`, `composability`, `readability`. Readability holds house style: anything that makes code hard to read. Composability holds code that must work with other types and future Julia versions.

Noise is no longer reason for group. Each finding says how sure analysis is. One setting picks what to report:

<div class="matrix" role="table" aria-label="Which findings each confidence setting reports">
      <div class="h" role="columnheader">finding</div><div class="h" role="columnheader">confidence = "definite" (default)</div><div class="h" role="columnheader">confidence = "possible"</div>
      <div role="cell"><code>definite</code> problem</div><div class="yes" role="cell">report</div><div class="yes" role="cell">report</div>
      <div role="cell"><code>possible</code> problem</div><div class="no" role="cell">skip</div><div class="yes" role="cell">report</div>
    </div>

Note: Checks with both kinds: `bang-convention` (dispatch past candidate budget may write), `type-disruption` (type branch), `unwritten-element` and `constant-array` (sites fixer cannot prove).

### Groups

`correctness`, `performance`, `composability`, `readability`. One group per check; `banned` entries name their own group.

### Confidence setting

`confidence` sets lowest confidence finding needs to be reported. `definite` (default): problem exists. `possible`: analysis ran and could not rule problem out; includes definite findings. Gaps in Corset itself are never `possible` findings; coverage line lists them. `likely` can join between them later.

### Lint levels

Clippy model: each group and each check has level `allow`, `warn` or `deny`; check level overrides group level. `deny` findings fail run; `--deny warnings` makes warnings fail too. Baseline findings never fail run.

### Opt-out comments

`# corset: allow <check> -- <reason>`. Reason is required. Opt-out that suppresses nothing is error, like Rust `#[expect]`. Scope by position: end of line covers line; line above function, struct or block covers that item; top of file covers file.

### Config

`[preferences.Corset]` table in Project.toml, read through Preferences.jl. Scripts without Project.toml use defaults and command-line flags.

### Project kind

Preset over groups and fix tier. Answers "who uses this code?"

| Kind | Groups | Fix tier |
|---|---|---|
| `library` | all four | `likely` |
| `application` | correctness, performance, readability | `breaking` |
| `script` | correctness, readability | `breaking` |

- Infer `script` for file with no Project.toml; `application` for Project.toml with no `name`. Otherwise setting is required.
- Preset sets levels: correctness `deny`, other listed groups `warn`, unlisted groups `allow`. Levels and tier stay overridable per project.

### Fix tiers

Each fix declares tier by risk to callers; one setting picks highest tier applied automatically. Test: would anyone's code need to change?

- `safe`: proven equivalent, or fixes definite bug inside method (`where-binding` parentheses, `untyped-empty` on local array).
- `likely`: changes types callers see (`overspecified-type`: `::Float64` → `::Real`).
- `breaking`: changes public API (`type-disruption` adds array-type parameter). Ratchet absorbs new findings.
- `manual`: needs human choice (new name, sum type). Shown, never applied. Later: prompt for choice in CLI, or hand off to LLM.

### Messages

Model: Rust compiler errors. Each finding carries primary span, labeled cause spans, one-line reason, fix with tier, and docs link. Analyses record cause spans (where union is created, where literal enters), so checks can name cause.

```
performance[vague-type]: `acc` changes type inside loop
  --> src/stats.jl:12:9
   |
10 |     acc = 0
   |     ------- starts as Int
11 |     for x in xs
12 |         acc += x
   |         ^^^^^^^^ becomes Float64 (x::Float64)
   |
   = why: later uses cannot compile for one type; each one dispatches at run time
   = fix: start from element type: `acc = zero(eltype(xs))`   [safe]
   = docs: corset explain vague-type
```

- Same structure feeds SARIF: related locations and fixes.
- `corset explain <check>` prints footgun, example and fix offline.
- Opt-out hint names exact comment: `# corset: allow vague-type -- <reason>`.

### Macro output

Findings inside macro expansions are reported, other packages' macros included: message marks them upstream and points at call site. Own macro: one finding at definition, with call-site count. Fixes never edit generated code. Syntax families see source as written; findings in expanded code come from families after load, placed by lowering provenance. Location without source mapping goes to coverage line.

### Conventions

- Corset supports only latest Julia release, for running and for fixes.
- Public API: exported or declared `public`. Everything else is internal.
- `test/`, `docs/`, `benchmark/` are scripts: loading them runs them.
- Baseline matches findings by check, file, enclosing definition and normalized snippet hash. No line numbers, so edits elsewhere keep matches.
- `corset explain` and docs page per check follow Clippy sections: what it does, why it is bad, example, use instead, known problems.
- Fixes keep surrounding style; formatting stays formatter's job (Runic, JuliaFormatter).
- Additive replacement for literal uses `oneunit(x)`, never `one(x)`: `one` drops units (Unitful.jl).
- Corset lints itself in CI from phase 1.
- Renamed check keeps old name as alias that warns, so opt-out comments survive renames (Clippy renamed-lints list).

### `one-letter` exemptions

Allowed: type names and type parameters (`T`, `N`); `i`, `j`, `k` as indices. Everything else needs descriptive name.
