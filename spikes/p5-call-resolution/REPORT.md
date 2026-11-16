# Spike P5: call resolution for write summaries

Verdict: go/no-go not met. Distances passes. DataStructures misses `possible` bar by 3 methods. JSON misses `possible` bar by 30 methods and time bar by 2.5×.

Engine is S5 engine (`spikes/s5-effect-summary`) plus call resolution. Signatures: declared, as in S5 baseline.

## Go/no-go (`docs/design/plan.md`, design reviews)

| Package | S5 `possible` | Bar | Spike `possible` | Effects, warm Base cache | `inference` stage |
|---|---|---|---|---|---|
| Distances 0.10.12 | 77% | 38.7% | 30.4% (86/283) | 0.58 s | 3.2 s |
| DataStructures 0.19.6 | 57% | 28.6% | 28.8% (417/1449) | 2.53 s | 3.0 s |
| JSON 1.13.4 | 61% | 30.4% | 35.8% (197/551) | 8.38 s | 3.3 s |

- `inference` stage column: cold times from `plan.md`, measured on DataStructures 0.18.22.
- Warm Base cache: second pass with fresh engine, seeded with summaries of methods outside package whose signature holds no package type. Summaries match first pass (`warm_diff`), except 3 JSON methods: SCC solve order changes them.
- JSON warm pass: 4.03 s IR inference, 4.35 s analysis. Package-owned instances take 88% of IR time; `inference` stage infers them already.
- Cold build, Base included: 72 s, 59 s, 83 s (`summary_s`). IR inference takes 13–23 s of it.
- Hand audit of 20 contract and join verdicts: not done.

## Call resolution added

- Contracts (`src/contracts.jl`): documented effect of generic Base function, used when dispatch stays unresolved.
- Join over candidate methods at declared signature; package functions join every loaded method.
- Must pass: recursive SCC promotes join-only `possible` to definite when every candidate agrees.
- Type-call records: callee from static parameter or `::Type` parameter (`D(kv)`); caller resolves it or records it again.
  - Parameter operand stays exact after later stores merge its class.
  - Relaxed position (`-j`) stays relaxed when caller records it again.
- Union of singleton callees (`Union{typeof(copyto!), typeof(adjoint!)}`): join over members.
- `Memory`/`MemoryRef` field of mutable struct shares owner class. `Array` and `Dict` elements then sit at depth 1, where contracts put stored values.
- Base default `getproperty`/`setproperty!` with constant field: field access (contract mode only; `convert` to field type is contract).
- Compiler `effect_free` (with `@assume_effects`) clears writes of instance. Corpus: zero conflicts with definite writes in 28k instances.
- Foreign table: read-only runtime queries (`jl_symbol_n`, type queries, `jl_idset_peek_bp`).

## Speed

- SCC worklist: member reanalyzes only after summary it read changed.
- Candidates memoized per IR statement. Type-keyed memo is slow: abstract `Tuple` types are not interned, so each lookup hashes type structure.
- Diagnostic callee names use `nameof`; printing types took 12% of warm pass.

## Rejected

- Wider candidate cap for type callees: no verdict changed; 12 s slower.
- Candidate cap 64 (earlier run): slower, no gain.

## Remaining `possible` (blame leaf of first write)

| DataStructures | n | JSON | n |
|---|---|---|---|
| alias | 186 | `String` too many candidates | 52 |
| type call `_` (`D(kv)`, `D` free) | 64 | alias | 41 |
| `_apply_iterate` unresolved | 22 | `setup_stdio` too many candidates | 19 |
| `map` too many candidates | 18 | `substrides` too many candidates | 12 |
| type call `convert` | 15 | `map` too many candidates | 12 |

- `alias`: graph is field-insensitive and flow-insensitive. Unknown call result unifies with every operand, so unrelated classes merge (`grow_to!`, `collect_to_with_first!`).
- Many JSON leaves are doubt in code at declared signature: `String(x)` with untyped `x` may truncate `Vector{UInt8}`. Doubt test reports them.

## Open decisions

- Field sensitivity: content class per field. Targets `alias` leaf; large engine change.
- Bar counts doubt in code at declared signatures; S5 baseline counted it too.
- Time: reuse `inference` stage IR for package instances; JSON analysis alone (4.35 s) still exceeds 3.3 s.

## Files

- `src/EffectSpike.jl`, `src/contracts.jl`: engine and contracts.
- `fixtures.jl`: `julia +1.13 --project=. fixtures.jl`; 115 tests. Modes: `S5_CONTRACTS=0`, `S5_PKGJOIN=0`, `S5_MUST=0`.
- `corpus.jl`, `run_trace.sh`: corpus run; `python3 score.py results stmt` prints table.
- `results/`: last corpus run (`stmt`), JSON warm-pass profile.
