# S3 scope layer: report

Verdict: **works with limits**. Use JuliaLowering vendored at julia commit `f0188d597b` on Julia 1.13.3; drop `Meta.lower` fallback (same coverage, line positions only).

## Setup
- `spikes/s3-scope-layer/setup.sh` vendors JuliaLowering + JuliaSyntax (sparse clone, git-ignored) at pin `f0188d597b35600751a8e3c7b08ac9a4f02103a1`, parent of `8597967694` (2026-10-08, moves `Syntax` into Base).
- julia master (`bc488cb792`) fails on 1.13: imports `Base.Syntax`, `Base.VERSION_EDITION` and ~30 more 1.14-only names.
- At pin, eval path (`include_string`) fails on 1.13 (`Base.VERSION_EDITION`); lowering passes work. Driver calls passes directly, evals no user code.
- Pin uses JuliaSyntax `2.0.0-DEV`; Julia 1.13 ships JuliaSyntax 1.x (`e8a07f51`). Both coexist.
- Julia 1.14.0-alpha2 ships `Base.JuliaLowering`; same driver calls run on fixture unchanged.

## Driver
- `scope_facts.jl`: parse to `SyntaxTree`, walk top-level forms (recurse `toplevel`, `module`, literal `include`), run `expand_forms_1`, `expand_forms_2`, `resolve_scopes`, `convert_closures`, `linearize_ir` per form.
- Facts from `BindingInfo`: kind, `is_captured`, `is_boxed`, `is_ambiguous_local`, `is_used_undef`, `node_id` bytes, macro provenance.
- Modes: `sandbox` (fresh module, eval `using`/`import` only) and `loaded` (lower inside loaded package module).
- Soft scope needs module state: driver declares each top-level assigned global as `global x::Any` (no user code).
- `overrides.jl`: syntax-macro stand-ins for `@doc @inline @noinline @inbounds @propagate_inbounds @simd @views @boundscheck @fastmath @assert`; keep bytes and scope, drop metadata.

## Measurements
Env: `JULIA_NUM_THREADS=2 JULIA_PROJECT=$PWD JULIA_LOAD_PATH="@:@stdlib"`. Command: `julia +1.13 --startup-file=no run_lowering.jl loaded|sandbox <Pkg> [overrides]`; fallback `meta_lower.jl loaded|sandbox <Pkg>`. Outputs in `out/` (`*-overrides.txt` and `meta-*` are current; other `jl-*` files predate `is_boxed` fix, provenance numbers still valid).

| Package | Forms | Scope OK loaded | Scope OK sandbox | Full lowering OK loaded |
|---|---|---|---|---|
| Distances 0.10.12 (1,859 lines) | 271 | 271 | 271 | 271 |
| DataStructures 0.19.6 (11,472) | 1,223 | 1,223 | 1,214 | 1,223 |
| JSON 1.13.4 (4,315) | 450 | 450 | 434 | 450 |
| script fixture | 13 | — | 13 | 13 |

Sandbox failures are package-own macros only (`@invariant`, `@delegate`, `@checkn`, `@nextbyte`, ...). `Meta.lower` fails on same 25 forms.

Reference provenance (binding-id leaves after scope resolution):

| Package | Exact bytes, no stand-ins | Exact bytes, stand-ins | Line only, stand-ins |
|---|---|---|---|
| Distances | 48% | 95% | 252 (`@warn`) |
| DataStructures | 53% | 99% | 192 (`@delegate`) |
| JSON | 65% | 83% | 2,312 (package macros, `@kwdef`, `@static`) |

Expr macros (all Base macros on 1.13) give `LineNumberNode` provenance; `@doc` alone costs 9,532 of 13,888 line-only refs in DataStructures. Line-only refs still get macro call bytes via `unexpanded_sourceref`.

Time, driver precompiled with PrecompileTools workload (`ScopeWarm/`, `out/timing-precompiled.txt`):

| Package | First run after package load | Warm rerun |
|---|---|---|
| Distances | 1.49 s (1.41 compile) | 0.06 s |
| DataStructures | 1.66 s (1.46 compile) | 0.17 s |
| JSON | 1.87 s (1.77 compile) | 0.11 s |

Without workload, first run compiles up to 10 s. Package load invalidates driver code; upstream `59a1406911` (after pin) targets this. Warm ≈ 0.15 s / 10k lines.

## Family H coverage
| Footgun | JuliaLowering | `Meta.lower` |
|---|---|---|
| 57 boxed-capture | `is_boxed` + decl bytes; corpus 3 boxes, matches flisp exactly | `Core.Box` slot, line |
| 61 soft-scope | `is_ambiguous_local` + bytes | top-level slot named like file global, form line |
| 62 try-scope | local-in-try + global read, bytes; needs scope tree (`ctx.scopes`) for detector; `is_used_undef` stays false | same clash, line, no scope tree |
| 63 world-age | syntactic (`@eval` expands via JL syntax macro) | syntactic |
| 69 threaded-race | box + `@threads` macro provenance | box only; `@threads` link needs syntax pass |

Raw local/global name clash is noisy (43/80/29 on corpus); 62 needs scope tree.

## Gaps
- Package macros need loaded package; sandbox reports coverage gap.
- Soft-scope fact depends on in-order global declaration; wrong order = silent miss.
- Package Expr macros stay line-only; stand-ins cover listed Base macros only.
- API internal (`BindingInfo`, `resolve_scopes`, `rebase_layers`).
- Family B on L2 not tested.

## Pinning cost
- 1.13: frozen vendor of JuliaLowering + JuliaSyntax 2.0.0-DEV; no upstream fixes after 2026-10-08; zero patches needed so far.
- 1.14: `Base.JuliaLowering`, no vendoring; pin per Julia minor (internal API). Corset supports latest release only, so vendoring ends when 1.14 ships.

## Design parts contradicted
- `docs/design/pipeline.md:9-10`: L2 above "package code runs below"; macro expansion needs evaluated imports and package macros, so L2 on packages needs L3.
- `docs/design/pipeline.md:9`: "per file"; lowering runs per top-level form against live module state, in include order.
- `docs/design/plan.md:22`: "try from source" — master no longer loads on 1.13; only pinned commit.
- `docs/design/families.toml:33` + `footguns.toml:609`: footgun 63 needs no scope facts; family A covers it.
- `docs/design/architecture.md:51,97`: fresh L2 run on package forces package load.


