# Architecture

Code layout, process model, cache, tests, command line.

### Code layout

Each layer is one module that produces facts. Checks read facts through one API. Engine is only module that knows order.

| Module | Job |
|---|---|
| `Syntax` | L1: parse files with JuliaSyntax package (tree type Argus.jl and TypedSyntax.jl take); index nodes by kind; array def-use (family B). |
| `Scope` | L2: lowering and scope facts (family H). JuliaLowering vendored at pinned julia commit on 1.13; `Base.JuliaLowering` from 1.14. Own replacement expansions for common Base macros keep byte positions. Soft scope: before lowering each form, declare earlier top-level assigned globals as `global x::Any`, in include order; order-sensitive fixtures. |
| `Load` | L3: load package; module facts (family C); Project.toml facts. |
| `Infer` | L4: stand-in types; one inference per method; typed IR with source mapping (family D). Mapping: vendored TypedSyntax.jl algorithm on L1 tree; no CodeTracking. |
| `Effects` | L5: effect and alias summary per method (family E). |
| `External` | Family G: Aqua.jl, ExplicitImports.jl, jscpd output as facts. |
| `Facts` | Fact types and query API. Only module check code may import. |
| `Checks` | One pure function per check; registry as data. |
| `Engine` | Salsa.jl query graph: pick layers that enabled checks need; run them; apply levels, confidence, opt-outs, baseline. |
| `Fix` | Apply edits to lossless tree; filter by tier. |
| `Report` | Render text, JSON, SARIF; `explain`. |
| `Cache` | Disk cache keys and storage. |
| `Config` | Preferences.jl table, presets, command-line overrides. |
| `CLI` | Julia app entry point. |

### Core types

```
struct Span     file::String; first_byte::Int; last_byte::Int; precision::Precision end  # exact or line
struct Label    span::Span; text::String end
struct Edit     span::Span; replacement::String end
struct Fix      edits::Vector{Edit}; tier::Tier end           # Tier: safe likely breaking manual
struct Finding
    check::Symbol; kind::Symbol; confidence::Confidence      # definite possible
    primary::Label; causes::Vector{Label}; why::String
    fix::Union{Fix, Nothing}
end
struct CheckEntry
    name::Symbol; group::Group; footguns::Vector{Int}; family::Family
    run::Function                                            # (facts::Facts) -> Vector{Finding}
end
```

### Process model

- One process. Corset runs inside target environment, like Aqua.jl and JET in tests.
- From tests: Corset is test dependency; `Corset.check()` in `runtests.jl` shares package load with test suite.
- From command line: build temporary environment from target Manifest and add Corset with every target version preserved; fail loud if any would change. Cache by Manifest hash.
- Load each extension's trigger packages: extension activates only when all triggers are loaded.
- Pkg resolves Corset dependencies with package dependencies, so conflict fails loudly at install.
- Cache check runs before package load: unchanged rerun loads nothing.

### Tests

- UI tests, as in Clippy: `test/ui/<check>/<case>.jl` with snapshot of full rendered output and fixed source. Bless command updates snapshots; CI fails on diff.
- Each footgun: positive case, negative case, fix case.
- Property tests (Supposition.jl): fix creates no new finding; fix is idempotent. `safe` fix: fixture behaves same before and after (differential run).
- Reference comparison: JET, fatou, LintApp.jl, ReLint.jl on fixtures, with allowlist.
- 100% line coverage; mutation testing on check code.

### Command line

| Command | Does |
|---|---|
| `corset check [path]` | Report findings. |
| `corset fix [path] [--tier T]` | Apply fixes up to tier (default from preset), then check again. |
| `corset explain <check>` | Print check docs offline. |
| `corset baseline [path]` | Write current findings to baseline. |

Flags: `-A`, `-W`, `-D <check or group>` set levels (Clippy style); `--deny warnings`; `--confidence definite|possible`; `--format text|json|sarif`; `--no-cache`.

Exit codes: `0` no `deny` finding; `1` `deny` finding; `2` config or usage error; `101` internal error (Cargo convention).

### Check contract

Main goal of rewrite: clean structure. Legacy implemented each rule on its own, so analyses repeated and code grew.

- Analysis (family) computes facts once per run: syntax index, array def-use, scopes, module facts, typed IR, effect summary.
- Check is one pure function: facts in, findings out. Check code imports only facts API; test enforces it.
- Check that needs new information adds fact to its analysis. Long check signals missing fact.
- Registry is data: name, group, footguns, family, fix tier. Docs page per check comes from footgun table.

### Package load

Loading runs code. Typed families (C, D, E, G) run only on package with `name`; Julia apps qualify. Scripts and nameless environments get A, B and H. Extensions are analyzed with test dependencies installed and their triggers loaded; `untested-extension` reports trigger missing from them. Later: definitions-only load for scripts.

### Incremental runs and disk cache

- Engine runs on Salsa.jl (julia-vscode, MIT; JuliaWorkspaces.jl uses it): inputs are file texts and Project.toml; derived queries are parse trees, facts and findings. Edit recomputes only dependents; early cutoff stops at unchanged facts.
- Salsa keeps tables in memory only. Disk cache stores findings (plain data) by input key, so new process starts warm.
- Inference runs inside compiler, outside Salsa tracking: typed dependencies come from compiler edges between methods.
- Empty cache: run prints one note: first analysis can be slow; later runs reuse cache.
- Location: user cache directory, one entry set per project. CI saves it between runs.
- Global key: Julia version, Corset version, config hash, Manifest hash, preferences, active extensions. Any change clears all entries.
- Syntax families: findings per file, keyed by file content hash.
- Typed families: findings per method, keyed by method source hash plus compiler dependency record: methods reached and method-table lookups (new, more specific method invalidates entry), struct definitions, globals. Dynamic call: key covers every method of called function. `@generated` method depends on whole package.
- Run parses every file (cheap) and computes keys. Nothing changed: no package load; cached findings print. Otherwise load package and infer only invalid methods.
- Later: warm daemon keeps Salsa tables and loaded package, so edit costs only its dependents.

### Reference linters

JET, fatou, LintApp.jl (`julialint`, julia-vscode linter; its checks live in JuliaWorkspaces, vendored StaticLint) and ReLint.jl run only in Corset tests, never at lint time. All four are MIT: copy their check code where it already implements our footgun, keeping license notice.

- Tests run each reference on fixture corpus and compare findings with Corset. `julialint` emits JSON and SARIF.
- Reference finding Corset misses: fix Corset, or record reason in allowlist (reference bug, different design).
- Corset finding reference misses: expected. Corset is stricter by design.
- Conflict is triage signal only; it never proves Corset wrong.
