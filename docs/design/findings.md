# Findings

How findings are graded, filtered, configured, shown and fixed.

Four groups: `correctness`, `performance`, `composability`, `readability`. Readability holds house style: anything that makes code hard to read. Composability holds code that must work with other types and future Julia versions.

Noise is no longer reason for group. Each finding says how sure analysis is. One setting picks what to report:

<div class="matrix" role="table" aria-label="Which findings each confidence setting reports">
      <div class="h" role="columnheader">finding</div><div class="h" role="columnheader">confidence = "definite" (default)</div><div class="h" role="columnheader">confidence = "possible"</div>
      <div role="cell"><code>definite</code> problem</div><div class="yes" role="cell">report</div><div class="yes" role="cell">report</div>
      <div role="cell"><code>possible</code> problem</div><div class="no" role="cell">skip</div><div class="yes" role="cell">report</div>
    </div>

Note: Rules with both kinds: `bang-convention` (dispatch candidates disagree on write, or call dispatches at run time), `type-disruption` (type branch), `unwritten-element` and `constant-array` (sites fixer cannot prove).

### Groups

`correctness`, `performance`, `composability`, `readability`. One group per rule, `banned` included.

### Confidence and blind spots

`confidence` sets lowest confidence finding needs to be reported. `definite` (default) reports definite findings only; `possible` reports both. `likely` can join between them later.

Doubt test: can Julia compiler resolve doubt? Compiler sees code, types and method table when it compiles call. It never sees run-time values, foreign code or methods added later.

| Compiler | Corset | Report |
|---|---|---|
| resolves; problem exists | proves problem | `definite` finding |
| cannot resolve | cannot resolve | finding: `possible`, or rule of its own |
| resolves | cannot resolve | blind spot: coverage line only |

- Finding: argument typed `Any` reaches methods that disagree on writing it. Compiler dispatches at run time: `bang-convention` reports `possible`, and `runtime-dispatch` reports call.
- Finding: public function returns union from dependency. Unknown callers decide: `possible`.
- Blind spot: syntax-only rule cannot see that `a::Vector` is 1-based, because `inference` stage did not run.
- Blind spot: inference refused generated method; macro did not expand; typed finding has no source span; `include` path is computed.
- Corset limits never fall below compiler limits (`max_methods`, union splitting). Corset resolves every call compiler resolves.

Coverage line ends every run and counts blind spots by cause: `analyzed 412 of 430 methods; skipped 18 (2 generated, 16 unexpanded macros)`. Rule that lacks fact at site reports nothing there.

### Lint levels

Clippy model: each group and each rule has level `allow`, `warn` or `deny`; rule level overrides group level from any source. Command-line flags beat config; config beats preset. `deny` findings fail run; `--deny warnings` makes warnings fail too. Baseline findings never fail run.

### Opt-out comments

Modeled on Rust lint attributes. `# corset: allow <rule>, <rule> -- <reason>`; reason is required. After code, comment covers that line. On own line, it covers next statement: function, struct, block or expression. `# corset: allow-file <rule> -- <reason>` before first code covers file, like Rust inner attribute `#![allow]`.

Malformed comment, unknown rule, late `allow-file`, and opt-out that suppresses nothing are errors; they always fail run, like unfulfilled `#[expect]` under `-D warnings`. Opt-outs apply to findings before levels and confidence filter, so config change never orphans opt-out.

### Parse errors

JuliaSyntax parse error is error finding at `deny`, outside rule table, as Ruff reports syntax errors. No level, opt-out or baseline hides it. Rules still run on recovered tree.

### Config

`[preferences.Corset]` table in target Project.toml; `[Corset]` table in LocalPreferences.toml overrides it key by key (Preferences.jl layout). Corset reads both files by path: target project is rarely active environment. Keys: `kind`, `confidence`, `fix_tier`, `levels` (group or rule name to level), `banned` (list of bans).
Each ban holds `reason` and one target: Argus `pattern`, or `name` regex that must match whole bound name. Unknown key, value or name is config error (exit 2). Scripts without Project.toml use defaults and command-line flags.

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

Model: Rust compiler errors. Each finding carries primary span, labeled cause spans, one-line reason, fix with tier, and docs link. Analyses record cause spans (where union is created, where literal enters), so rules can name cause. Span has precision: exact bytes or line only. Renderer marks whole line for line precision.

```
warning[vague-type]: `acc` changes type inside loop
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
   = note: warn from performance group, library preset
   = note: opt out with `# corset: allow vague-type -- <reason>`
```

- Header names level as rustc does: `error` for `deny`, `warning` for `warn`. Note line says where level was set, once per rule per run.
- Same structure feeds SARIF: related locations and fixes.
- `corset explain <rule>` prints footgun, example and fix offline.
- Opt-out hint names exact comment, once per rule per run: `# corset: allow vague-type -- <reason>`.

### Macro output

Rules read code as written, macro arguments included. Code that package macro writes gets findings: one finding at macro definition, with call-site count. Code that other packages' macros write gets none, since package cannot fix it (Clippy `in_external_macro`). Fixes never edit generated code. Syntax stage sees source as written; findings in expanded code come from stages after load. Syntax stage skips quoted code outside `$` interpolation, and macro arguments with `{}` (Argus patterns), which lowering always rejects. `{}` check is stopgap; revisit with general check in plan later row. Code passed through macro (`@inbounds`, `@views`) maps to exact bytes. Code macro writes itself (macro body, `@generated`) maps to nearest line inside definition. Julia 1.13 lowering keeps no call-site provenance (S2); JuliaLowering on 1.14 fixes it. Location without source mapping goes to coverage line.

### Conventions

- Corset supports only latest Julia release, for running and for fixes.
- Public API: exported or declared `public`. Everything else is internal.
- `test/`, `docs/`, `benchmark/` are scripts: loading them runs them.
- Baseline lives in `corset-baseline.toml` at project root; `corset baseline` writes it. Entries match findings by rule, file, enclosing definition and normalized snippet hash. No line numbers, so edits elsewhere keep matches. Baselined findings stay hidden. Entry that matches no finding fails run until `corset baseline` rewrites file, like ESLint bulk suppressions.
- `corset explain` and docs page per rule follow Clippy sections under plain headings: Description, Rationale, Example, Alternative, Limitations. Text lives in rule module docstring; registry test enforces sections.
- Fixes keep surrounding style; formatting stays formatter's job (Runic, JuliaFormatter).
- Additive replacement for literal uses `oneunit(x)`, never `one(x)`: `one` drops units (Unitful.jl).
- Corset lints itself in CI from phase 1.
- Renamed rule keeps old name as alias that warns, so opt-out comments survive renames (Clippy renamed-lints list).

### `one-letter` exemptions

Allowed: type names and type parameters (`T`, `N`); `i`, `j`, `k` as indices. Everything else needs descriptive name.
