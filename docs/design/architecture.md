# Architecture

Code layout, process model, cache, tests, command line.

### Code layout

Each stage is one module that produces facts. Rules read facts through one API. Engine is only module that knows order.

| Module | Job |
|---|---|
| `Discovery` | Files to analyze: package entry files and their include closure, or Julia files under directory. |
| `Syntax` | `syntax` stage: parse files with JuliaSyntax package (tree type Argus.jl and TypedSyntax.jl take); index nodes by kind. |
| `Scope` | `scope` stage: lowering and scope facts. JuliaLowering vendored at pinned julia commit on 1.13; `Base.JuliaLowering` from 1.14. Own replacement expansions for common Base macros keep byte positions. Soft scope: before lowering each form, declare earlier top-level assigned globals as `global x::Any`, in include order; order-sensitive fixtures. |
| `Package` | `package` stage: load package; module facts; Project.toml facts. |
| `StandIns` | Stand-in types: float, integer, array, dense array and function. |
| `Signatures` | Stand-in signatures per package method: stand-ins for generic arguments and type variables; at most 8 per method. |
| `Inference` | `inference` stage: native inference of unoptimized code on stand-in signatures; worklist follows calls into untyped package methods. TypedSyntax.jl maps statements onto `syntax` stage tree; callee check demotes doubtful spans to line. |
| `Effects` | `effects` stage: effect and alias summary per method. |
| `Lifecycle` | `lifecycle` stage: local def-use per array; callee writes from `effects`. |
| `External` | `external` stage: Aqua.jl, `Test.detect_ambiguities` and ExplicitImports.jl output as facts; jscpd later. |
| `Facts` | Fact types and query API. Only module rule code may import. |
| `Rules` | One pure function per rule; registry as data. |
| `Engine` | Salsa.jl query graph: pick stages that enabled rules need; run them; apply levels, confidence, opt-outs, baseline. |
| `Fix` | Apply edits to lossless tree; filter by tier. Fix that edits several files applies whole or not at all. |
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

- One process per run. Corset loads target into its own process, as Aqua.jl and JET do, so later stages read compiler state directly.
- Fresh process only: no `Corset.check()` inside `runtests.jl`. Test code would change method table, and `--code-coverage` changes optimized IR, so findings would depend on what ran before.
- Command line always builds temporary environment: nameless project that develops target by path, starts from target Manifest, and adds test dependencies and Corset by path. Every target version stays when Corset accepts it. Otherwise packages Corset shares with target move, fewest first: Corset direct dependencies, then its dependency closure. Build prints each move; coverage line counts each loaded package at other version than Manifest pins as blind spot. Target compat that blocks every move fails loud (exit 2). Cache environment by hash of Manifest, Project.toml, Julia version and Corset version.
- Relaunch Julia with `JULIA_LOAD_PATH` set to that environment and `@stdlib` only, so default environment (`@v#.#`) adds no package, trigger or method.
- Package stage loads in place only there and in Corset tests: `Base.locate_package` must give target entry file by real path. Other path is internal error: findings would describe other code.
- Load each extension's trigger packages: extension activates only when all triggers are loaded.
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

Install: `pkg> app add Corset` puts `corset` on PATH (Julia app); `julia -m Corset` runs same entry point. Text output ends with count line (errors, warnings, baselined), then coverage line. JSON report has version field; SARIF 2.1.0 log counts columns in code points and carries byte offsets, related locations and fixes.

Files, as Cargo picks targets:

- Package or app root (Project.toml with `name`): entry files and every file they include. Entries: `src/<name>.jl`, extension files, `test/runtests.jl`, `docs/make.jl`, `benchmark/benchmarks.jl`.
- File: file and every file it includes.
- Other directory: Julia files under it, without hidden directories, symbolic links and nested projects.
- Include path: string literal, `@__DIR__` or `joinpath` of those. Computed path or missing file goes to coverage line.
- Missing module or extension file is config error.

Exit codes: `0` no `deny` finding; `1` `deny` finding; `2` config or usage error; `101` internal error (Cargo convention).

### Rule contract

Main goal of rewrite: clean structure. Legacy implemented each rule on its own, so analyses repeated and code grew.

- Each stage computes facts once per run: syntax index, array def-use, scopes, module facts, typed IR, effect summary.
- Rule is one pure function: facts in, findings out. Rule code imports only facts API; test enforces it.
- Rule that needs new information adds fact to its analysis. Long rule signals missing fact.
- Registry is data: name, group, footguns, stage, fix tier. Docs page per rule comes from footgun table.

### Package load

Loading runs code. Stages after package load (`package`, `inference`, `effects`, `lifecycle`, `external`) run only on package with `name`; Julia apps qualify. Scripts and nameless environments get `syntax` and `scope`. Extensions are analyzed with test dependencies installed and their triggers loaded; `untested-extension` reports trigger missing from them. Later: definitions-only load for scripts.

Engine loads package only when enabled rule needs stage after `syntax`. Load that throws becomes `load-error` finding (`findings.md`).

`package` facts hold live objects (`Module`, `Method`, `DataType`); findings stay plain data. Package code: methods and types whose module is package module (root, submodules, extensions) and whose file lies under package root. Code that other packages' macros write elsewhere is not package code.

Method span: `package` stage pairs each method with definition node at its file and line. Exact span when one definition node of that name starts there; line precision otherwise (`@eval` loops, macro output).

UI cases for rules after `syntax`: case directory holds package (Project.toml with `name` and `uuid`, `src/`). Harness loads it in test process under unique name. Fixture that extends function it does not own (`piracy`) adds only methods no other case calls, so later cases see same dispatch.

### Incremental runs and disk cache

- Disk cache (`Cache`) holds one entry per checked path: key line, then serialized analysis. Analysis holds leveled diagnostics, baseline keys, check problems, blind spots and analyzed files. Settings and baseline apply each run.
- Key: SHA-256 of Julia version, `Base.CacheFlags`, checked path, serialized flags, each load path environment with Manifest and preferences, Corset source, analyzed files, and every file of project root and Manifest `path` entries.
- Key reads file content, so fresh CI checkout hits. Names that start with dot, `.cov` and `.mem` files, and cache directory stay out of key.
- Location: Corset scratch space `analyses` in Julia depot. CI that saves depot keeps cache. `--no-cache` turns cache off.
- Relaunching process computes key of relaunched process (temporary environment, load path `@:@stdlib`) and asks cache first. Hit loads no package and starts no process. `fix` always relaunches.
- Empty cache: run prints one note: first analysis can be slow; later runs reuse cache.
- Later, per-file and per-method entries. `syntax` stage: findings per file, keyed by file content hash.
- Later, typed stages: findings per method, keyed by method source hash plus compiler dependency record: methods reached and method-table lookups (new, more specific method invalidates entry), struct definitions, globals. Dynamic call: key covers every method of called function. `@generated` method depends on whole package. Run then loads package and infers only invalid methods.
- Later, engine runs on Salsa.jl (julia-vscode, MIT; JuliaWorkspaces.jl uses it): inputs are file texts and Project.toml; derived queries are parse trees, facts and findings. Edit recomputes only dependents; early cutoff stops at unchanged facts. Salsa keeps tables in memory only; disk cache starts new process warm.
- Inference runs inside compiler, outside Salsa tracking: typed dependencies come from compiler edges between methods.
- Later: warm daemon keeps Salsa tables and loaded package, so edit costs only its dependents.

### Reference linters

JET, fatou, LintApp.jl (`julialint`, julia-vscode linter; its rules live in JuliaWorkspaces, vendored StaticLint) and ReLint.jl run only in Corset tests, never at lint time. All four are MIT: copy their rule code where it already implements our footgun, keeping license notice.

- Tests run each reference on fixture corpus and compare findings with Corset. `julialint` emits JSON and SARIF.
- Reference finding Corset misses: fix Corset, or record reason in allowlist (reference bug, different design).
- Corset finding reference misses: expected. Corset is stricter by design.
- Conflict is triage signal only; it never proves Corset wrong.
