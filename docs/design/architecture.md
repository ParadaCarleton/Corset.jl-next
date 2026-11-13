# Architecture

Code layout, process model, cache, tests, command line.

### Code layout

Each stage is one module that produces facts. Rules read facts through one API. Engine is only module that knows order.

| Module | Job |
|---|---|
| `Syntax` | `syntax` stage: parse files with JuliaSyntax package (tree type Argus.jl and TypedSyntax.jl take); index nodes by kind. |
| `Scope` | `scope` stage: lowering and scope facts. JuliaLowering vendored at pinned julia commit on 1.13; `Base.JuliaLowering` from 1.14. Own replacement expansions for common Base macros keep byte positions. Soft scope: before lowering each form, declare earlier top-level assigned globals as `global x::Any`, in include order; order-sensitive fixtures. |
| `Package` | `package` stage: load package; module facts; Project.toml facts. |
| `Inference` | `inference` stage: stand-in types; one inference per method; typed IR with source mapping. Mapping: vendored TypedSyntax.jl algorithm on syntax tree; no CodeTracking. |
| `Effects` | `effects` stage: effect and alias summary per method. |
| `Lifecycle` | `lifecycle` stage: local def-use per array; callee writes from `effects`. |
| `External` | `external` stage: Aqua.jl, ExplicitImports.jl, jscpd output as facts. |
| `Facts` | Fact types and query API. Only module rule code may import. |
| `Rules` | One pure function per rule; registry as data. |
| `Engine` | Salsa.jl query graph: pick stages that enabled rules need; run them; apply levels, confidence, opt-outs, baseline. |
| `Fix` | Apply edits to lossless tree; filter by tier. |
| `Report` | Render text, JSON, SARIF; `explain`. |
| `Cache` | Disk cache keys and storage. |
| `Config` | Project.toml and LocalPreferences.toml tables, presets, command-line flags; level per rule. |
| `CLI` | Julia app entry point. |

### Core types

```
struct Span     file::String; first_byte::Int; last_byte::Int; precision::Precision end  # exact or line
struct Label    span::Span; text::String end
struct Edit     span::Span; replacement::String end
struct Fix      edits::Vector{Edit}; tier::Tier end           # Tier: safe likely breaking manual
struct Finding
    rule::Symbol; kind::Symbol; confidence::Confidence      # definite possible
    primary::Label; causes::Vector{Label}; why::String
    fix::Union{Fix, Nothing}
end
struct Diagnostic finding::Finding; level::Level; source::String end   # source: where level was set
struct RuleEntry
    name::Symbol; group::Group; footguns::Vector{Int}; stage::Stage
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

- UI tests, as in Clippy: `test/ui/<rule>/<case>.jl` with snapshot of full rendered output and fixed source. Bless command updates snapshots; CI fails on diff.
- Each footgun: positive case, negative case, fix case.
- Property tests (Supposition.jl) on programs built from UI case statements, with expressions spliced into value positions so fixes nest. Fixed code parses and lowers when original did. On code Julia accepts, fix removes its finding and adds none; `duplicate-statement` compares neighbors and is exempt. Fix runs converge. Equivalent `safe` fix keeps parsed meaning.
- Differential run: `safe` fix behaves same before and after on executed fixture. Not built yet.
- Reference comparison: JET, fatou, LintApp.jl, ReLint.jl on fixtures, with allowlist.
- 100% line coverage; mutation testing on rule code.

### Command line

| Command | Does |
|---|---|
| `corset check [path]` | Report findings. |
| `corset fix [path] [--tier T]` | Apply fixes up to tier (default from preset), then check again. |
| `corset explain <rule>` | Print rule docs offline. |
| `corset baseline [path]` | Write current findings to baseline. |

Flags: `-A`, `-W`, `-D <rule or group>` set levels and apply in order, as in rustc; `-D warnings` fails run on warnings; `--confidence definite|possible`; `--format text|json|sarif`; `--tier safe|likely|breaking` for `fix`; `--no-cache`.

Install: `pkg> app add Corset` puts `corset` on PATH (Julia app); `julia -m Corset` runs same entry point. Text output ends with count line: errors, warnings, baselined. JSON report has version field; SARIF 2.1.0 log counts columns in code points and carries byte offsets, related locations and fixes.

Exit codes: `0` no `deny` finding; `1` `deny` finding; `2` config or usage error; `101` internal error (Cargo convention).

### Rule contract

Main goal of rewrite: clean structure. Legacy implemented each rule on its own, so analyses repeated and code grew.

- Each stage computes facts once per run: syntax index, array def-use, scopes, module facts, typed IR, effect summary.
- Rule is one pure function: facts in, findings out. Rule code imports only facts API; test enforces it.
- Rule that needs new information adds fact to its analysis. Long rule signals missing fact.
- Registry is data: name, group, footguns, stage, fix tier. Docs page per rule comes from footgun table.

### Package load

Loading runs code. Stages after package load (`package`, `inference`, `effects`, `lifecycle`, `external`) run only on package with `name`; Julia apps qualify. Scripts and nameless environments get `syntax` and `scope`. Extensions are analyzed with test dependencies installed and their triggers loaded; `untested-extension` reports trigger missing from them. Later: definitions-only load for scripts.

### Incremental runs and disk cache

- Engine runs on Salsa.jl (julia-vscode, MIT; JuliaWorkspaces.jl uses it): inputs are file texts and Project.toml; derived queries are parse trees, facts and findings. Edit recomputes only dependents; early cutoff stops at unchanged facts.
- Salsa keeps tables in memory only. Disk cache stores findings (plain data) by input key, so new process starts warm.
- Inference runs inside compiler, outside Salsa tracking: typed dependencies come from compiler edges between methods.
- Empty cache: run prints one note: first analysis can be slow; later runs reuse cache.
- Location: user cache directory, one entry set per project. CI saves it between runs.
- Global key: Julia version, Corset version, config hash, Manifest hash, preferences, active extensions. Any change clears all entries.
- `syntax` stage: findings per file, keyed by file content hash.
- Typed stages: findings per method, keyed by method source hash plus compiler dependency record: methods reached and method-table lookups (new, more specific method invalidates entry), struct definitions, globals. Dynamic call: key covers every method of called function. `@generated` method depends on whole package.
- Run parses every file (cheap) and computes keys. Nothing changed: no package load; cached findings print. Otherwise load package and infer only invalid methods.
- Later: warm daemon keeps Salsa tables and loaded package, so edit costs only its dependents.

### Reference linters

JET, fatou, LintApp.jl (`julialint`, julia-vscode linter; its rules live in JuliaWorkspaces, vendored StaticLint) and ReLint.jl run only in Corset tests, never at lint time. All four are MIT: copy their rule code where it already implements our footgun, keeping license notice.

- Tests run each reference on fixture corpus and compare findings with Corset. `julialint` emits JSON and SARIF.
- Reference finding Corset misses: fix Corset, or record reason in allowlist (reference bug, different design).
- Corset finding reference misses: expected. Corset is stricter by design.
- Conflict is triage signal only; it never proves Corset wrong.
