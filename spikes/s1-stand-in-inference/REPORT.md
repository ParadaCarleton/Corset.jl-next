# S1 stand-in inference: report

Verdict: **works with limits** on Julia 1.13.3.
Native inference runs every corpus method with stand-ins: no stand-in ambiguity at call sites, 2 generated methods refused.
Differential check decides every fixture correctly.
`never-succeeds` can separate stand-in gaps from real failures: re-dispatch failing call on model types.
Limits: coverage of unannotated code, opaque function results, index arithmetic findings. See design consequences.

## Code

- `src/StandIns.jl`: `FloatStandIn` (wraps `Float32`), `IntStandIn` (wraps `Int32`), `ArrayStandIn{T,N}` (wraps `Array`), `FunctionStandIn` (returns `OpaqueResult()`). 206 lines.
- `src/Signatures.jl`: method signature to stand-in signatures. Type variables from bounds; `Real` runs both number stand-ins; package abstract type runs each concrete package subtype; struct parameters come from bounds; at most 8 signatures per method.
- `src/Scan.jl`: inference via `Compiler.typeinf_ircode(NativeInterpreter(), method, atype, sparams, "CC: COMPACT_1")`. It gives SSA IR before inlining, so literals stay call operands. `Union{}` classifier, literal differential, package callee worklist.
- `run.jl`: corpus driver. `fixtures.jl`: differential fixtures.

## Reproduce

```sh
cd spikes/s1-stand-in-inference
JULIA_NUM_THREADS=2 julia --project=. -e 'using Pkg; Pkg.instantiate()'
S1_WARM=1 JULIA_NUM_THREADS=2 julia --project=. --startup-file=no run.jl Distances   # also DataStructures, JSON
JULIA_NUM_THREADS=2 julia --project=. --startup-file=no fixtures.jl
```

Output: `results/<pkg>.txt`, `results/fixtures.txt`.

## Measurements

Corpus: Distances 0.10.12, DataStructures 0.19.6, JSON 1.13.4. Host shared with other jobs; times are rough.

| | Distances | DataStructures | JSON |
|---|---|---|---|
| package methods | 283 | 1449 | 553 |
| own signature has stand-in | 118 | 147 | 26 |
| declared types only (concrete, `Any`, no stand-in) | 165 | 1302 | 525 |
| inference failed | 0 | 0 | 2 (generated, free `T`) |
| extra methods scanned through callers | 74 | 28 | 1 |
| signatures inferred | 1201 | 1574 | 591 |
| cold scan, s | 16.6 | 7.5 | 9.3 |
| warm scan (same process), s | 6.3 | 0.53 | 0.42 |
| process wall, s (startup + cold + warm) | 25 | 10 | 12 |
| max RSS, MB | 508 | 426 | 463 |

Argument notes (methods with at least one such argument):

| note | Distances | DataStructures | JSON |
|---|---|---|---|
| no stand-in (`AbstractString`, `AbstractDict`, `IO`, unions) | 48 | 709 | 221 |
| struct parameters filled from bounds | 31 | 439 | 108 |
| package abstract type, per concrete subtype | 44 | 13 | 33 |
| array without stand-in (`StridedArray`, `DenseArray`) | 1 | 72 | 13 |

### `Union{}` calls by class

`never-succeeds` reports only `real_*` and `undefined_global`. Every other class is analysis gap or explicit throw.

| class | Distances | DataStructures | JSON |
|---|---|---|---|
| explicit_throw (`throw`, `error`, `throw_*`, `kwerr`) | 566 | 157 | 84 |
| callee_throws (callee also throws on model types) | 9 | 8 | 31 |
| opaque_result / opaque_in_callee | 17 | 2 | 0 |
| stand_in_gap_* (model types succeed) | 4 | 6 | 1 |
| undecided (abstract args, computed callee) | 1 | 4 | 1 |
| only_default_type_works | 0 | 6 | 0 |
| real_no_method | 0 | 1 | 0 |

Classifier (`Scan.classify_bottoms`):

1. Callee is thrower (`throw`, `error`, `kwerr`, name starts `throw`/`_throw`): `explicit_throw`.
2. Argument holds `OpaqueResult` or `FunctionStandIn`: `opaque_*`, outside analysis.
3. Argument holds stand-in: replace each stand-in by model type (`Float32`, `Int32`, `Array`). If that call dispatches and returns: `stand_in_gap_<dispatch status>`. Ignored; listed in coverage.
4. Still no method, but `Int`/`Float64`/`Vector` dispatch: `only_default_type_works`. Signature promises more than it delivers.
5. Abstract arguments: `undecided`. No method with concrete arguments: `real_no_method`.

Stand-in gaps found: `pop!(::ArrayStandIn)`, `eigmin(::ArrayStandIn)` (LinearAlgebra wants strided), `parse(::Type{FloatStandIn}, ::AbstractString)`, `heappop!` downstream of `pop!`.
Each gap is one forwarding method on stand-in. Classifier catches all of them; none leaks as finding.

Real findings, checked at run time:

- `DataStructures.empty(::DefaultDictBase)` (`src/default_dict.jl:84`) calls `DefaultDictBase{K,V,F}(...)`. No 3-parameter constructor exists: `MethodError`. True positive.
- `DataStructures._minmax_heap_trickle_down!(A, i::Integer)` (`src/heaps/minmax_heap.jl:81`) calls `children_and_grandchildren(length(A), i)`, which needs both arguments of same `T`. `Int32` index gives `MethodError`. Latent bug; internal API, so `possible` at most.

### Literal sites

| (kind, escape) | Distances | DataStructures | JSON |
|---|---|---|---|
| int_literal, no_change | 682 | 41 | 4 |
| int_literal, not_operand (index, field number) | 46 | 8 | 0 |
| int_literal, intermediate | 26 | 18 | 2 |
| type_name, intermediate | 0 | 9 | 3 |
| type_name, not_operand | 0 | 2 | 0 |
| **int_literal, returned (finding)** | **0** | **4** | **0** |

Integer-literal findings: 4, all in DataStructures heap index helpers:
`heapleft(i::Integer) = 2i`, `lchild`, `heapparent = div(i, 2)`, `hparent`. Each returns `Int64` for `Int32` input. Correct under rule; low value, since values are array indices.
No float-literal site met float stand-in in corpus. Distances uses `zero(T)` and integer literals that `FloatStandIn` absorbs.

### Differential prototype (`results/fixtures.txt`)

Site: literal, constant or concrete number type meets operand holding number stand-in. Override literal type with stand-in; recompute types forward through SSA uses (calls via `Base.infer_return_type`, builtins via `builtin_tfunction`, phi via `tmerge`). Compare at returns and at stores into arguments.

| fixture | expected | result |
|---|---|---|
| `x::Integer * 2` | report | returned, Int64 vs IntStandIn |
| `x::Real * 0.5` | report (float case) | returned, Float64 vs FloatStandIn; int case skipped |
| `Float32(x * 0.5)` | intermediate | intermediate |
| `x::Integer / 2`, `x::AbstractFloat * 2` | pass | no_change |
| `Float64(x::AbstractFloat)` | report | returned (type_name) |
| `y = x + 1` then loop `y += x` | report | returned, through loop phi |
| `s = 0; for x in v; s += x; end` | report | returned; literal in two phis grouped |
| `s = zero(eltype(v))` | pass | no site |
| `v[1] + v[2]` | pass | no_change / not_operand |
| `SCALE * x` (`const SCALE = 3`) | report | returned (constant) |
| `v[1] = x * 2` | pass (store converts) | intermediate |
| `1:n` | open question | returned, `UnitRange{Int64}` |

Decidable: each site needs at most 4 forward passes over one frame's IR. Filters were required:

- `not_operand`: override makes call return `Any` or `Union{}`, so literal is index or field number. Skip.
- Type names: same kind only (`Float64(x::AbstractFloat)`). `UInt64(i)` and `Float64(i::Integer)` are intended kind changes.
- Phi literal: one source literal becomes operand of several phis (loop head and exit). Override all phis reachable from first one, else result is false union.
- Phi start: back-edge operands start at `Union{}`; pessimistic start keeps union forever.
- Store: concrete field or element type means store converts; no escape.

## Gaps found

- Stand-in fidelity: Base special-cases `Float32` against irrationals (`irrationals.jl:45`). Without own rule, `FloatStandIn * π` gives `Float64`. Stand-in must copy every `Float32` and `Int32` special case that changes result type.
- Stand-in ambiguities: first draft had 9 ambiguities with Base (`round(x, ::RoundingMode{:FromZero})`, `^(::Integer, ::Bool)`, `rem(x, ::Type{Unsigned})`, `Rational{BigInt}(::AbstractFloat)`). Fix: narrower signatures. Keep `Test.detect_ambiguities` in stand-in test suite.
- Arrays: `ArrayStandIn <: AbstractArray` gets no `DenseArray`/`StridedArray` arguments (86 methods) and fails `eigmin`. Array escape sites are not measured; prototype covers numbers only. Broadcast with kind-carrying style keeps `ArrayStandIn` (`a .+ zeros(n)` gives `ArrayStandIn{Float64}`), so array disruption comes from `zeros`/`Vector{T}(undef, n)` returns.
- Generated functions with free type variables: inference refuses (JSON `_typename`, `maketuple`).
- Warm Distances scan stays 6 s. Likely cause: differential calls `infer_return_type` on abstract signatures. Not profiled.
- Internal API: `typeinf_ircode`, pass name `"CC: COMPACT_1"`, `jl_type_intersection_with_env`, `Base.visit(Core.methodtable)`. Pin per Julia minor version.
- Source lines: `Base.IRShow.buildLineInfoNode` gives method-level lines for most statements. S2 (TypedSyntax) must give exact spans.

## Design consequences

1. **Coverage of unannotated code** (`types.md:14`). Distances entry points `(d::Euclidean)(a, b)` have no annotations: 165 of 283 methods have no stand-in. Only 74 get scanned through annotated callers (`pairwise`). Family D needs explicit callee worklist: scan each package frame reached from stand-in caller (`families.toml:23` says "one pass per inferred frame"; make it explicit). Expect low numeric coverage until `annotation` fixer runs.
2. **Opaque function result** (`types.md:12`). Opaque struct turns every later use into `Union{}`. It truncates frames and needs classes `opaque_result`/`opaque_in_callee` (19 calls; all `Bregman` paths in Distances). Returning `Any` (inference barrier) keeps later code analyzed, with same "no findings from that data" effect. Recommend `Any`, or keep opaque and accept truncation.
3. **`never-succeeds` needs model-type re-dispatch** (`footguns.toml:248`, `plan.md:20`). Rule "`Union{}` without explicit `throw`" is not enough: 31 JSON `callee_throws` are package throw helpers (`invalid`, `toodeep`); report at deepest frame only. Add class `only_default_type_works` (diagonal `T` mismatch) as `possible`.
4. **Index arithmetic** (`types.md:31-33`). All 4 integer-literal findings are index arithmetic on `i::Integer`; `1:n` also reports. Decide: keep (rule is correct), give `possible`, or exempt values that only reach `getindex` or ranges.
5. **Cost estimate** (`types.md:41`). Number stand-ins: about 200 lines, as estimated. Mixing check (differential, escape, filters, classifier): about 360 lines, above 100–200 estimate. Signature mapping (about 190 lines) has no estimate in design.
6. **"Promotes like narrowest type"** (`types.md:28`) holds only with copied `Float32` special cases (irrational rule). State it in design.
7. **Speed**: 7–17 s cold scan per package; warm under 1 s except Distances. Per-method disk cache (phase 4) is needed for "rerun under 1 s" (`plan.md:36`). Legacy baseline is not measured here.
