# Spike P5: call resolution for write summaries

Verdict: go/no-go not met. Distances passes. DataStructures misses `possible` bar by 3 methods. JSON misses `possible` bar by 46 methods and time bar by 2.8×.

Engine is S5 engine (`spikes/s5-effect-summary`) plus call resolution. Signatures: declared, as in S5 baseline.

## Go/no-go (`docs/design/plan.md`, design reviews)

| Package | S5 `possible` | Bar | Spike `possible` | Effects, warm Base cache | `inference` stage |
|---|---|---|---|---|---|
| Distances 0.10.12 | 77% | 38.7% | 30.4% (86/283) | 0.58 s | 3.2 s |
| DataStructures 0.19.6 | 57% | 28.6% | 28.8% (417/1449) | 2.62 s | 3.0 s |
| JSON 1.13.4 | 61% | 30.4% | 38.7% (213/551) | 9.19 s | 3.3 s |

- `inference` stage column: cold times from `plan.md`, measured on DataStructures 0.18.22.
- Warm Base cache: second pass with fresh engine, seeded with summaries of methods outside package whose signature holds no package type. Summaries match first pass (`warm_diff`), except 3 JSON methods: SCC solve order changes them.
- JSON warm pass: 4.26 s IR inference, 4.93 s analysis. Package-owned instances take 88% of IR time; `inference` stage infers them already.
- Cold build, Base included: 86 s, 67 s, 100 s (`summary_s`); 59–100 s across runs on loaded `ssh-dev`.
- Hand audit of 20 contract and join verdicts: not done. Comparison below found 13 false definite in JSON; fixed.

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
- Repair methods (`REPAIRS`): Base methods whose writes restore internal state no caller observes.
  - `unsafe_convert(::Type{Ref{BigFloat}}, ::BigFloatData)` rewrites stale limb self-pointer before each MPFR call.
  - Without it, every function passing `BigFloat` to MPFR writes its argument: 13 false definite in JSON (`json`, `print`, `_bigfloatstring`).
  - IR stops before inlining (`PASS`), so repair code always runs as own instance.

## Speed

- SCC worklist: member reanalyzes only after summary it read changed.
- Candidates memoized per IR statement. Type-keyed memo is slow: abstract `Tuple` types are not interned, so each lookup hashes type structure.
- Diagnostic callee names use `nameof`; printing types took 12% of warm pass.

## Rejected

- Wider candidate cap for type callees: no verdict changed; 12 s slower.
- Candidate cap 64 (earlier run): slower, no gain.
- Repair check by inlining frames per write: dead code under `PASS`; 0.4 s slower on Distances.

## Comparison with julia-anal

`compare/`: julia-anal `contrib/strict/mutation.jl` (`1.13/strict/bang-analysis` on ParadaCarleton/julia) on same 1,774 named methods.

| Analysis | Undecided | No write | Writes | Time per package |
|---|---|---|---|---|
| julia-anal branch tip: callees followed, `unknown` when stuck | 68% | 11% | 21% | 61–85 s |
| julia-anal parent of b88a7fe198: `FINDINGS.md` "92.6% ok" | 0% | 80% | 19% | 0.3 s |
| Spike P5 | 24% | 56% | 20% | 0.6–9.2 s |

- Parent trusts names: callee without `!` writes nothing; callee with `!` writes first argument.
  - Misses writes: DataStructures `in(::SplayTree)` splays, `in_same_set` compresses paths.
  - Calls 28 `!` methods clean (`get!`, `pop!`, `filter!`, `setdiff!`, `pairwise!`).
  - Calls 401 of spike `possible` methods clean without evidence.
- Branch tip reads lowered IR without types: `methods(f, Tuple{Any, …})` exceeds 4 candidates at most generic calls.
- julia-anal write, spike none (5): 3 julia-anal false positives (fresh `new()`, fresh buffer), 1 callable struct writing itself (spike exempts `self`), 1 write in catch block that always rethrows (spike skips error paths).

## Remaining `possible` (blame leaf of first write)

| DataStructures | n | JSON | n |
|---|---|---|---|
| alias | 186 | `String` too many candidates | 53 |
| type call `_` (`D(kv)`, `D` free) | 64 | alias | 47 |
| `_apply_iterate` unresolved | 22 | `setup_stdio` too many candidates | 19 |
| `map` too many candidates | 18 | `invoke_in_world` candidate without summary | 16 |
| type call `convert` | 15 | `substrides` too many candidates | 12 |

- `alias`: graph is field-insensitive and flow-insensitive. Unknown call result unifies with every operand, so unrelated classes merge (`grow_to!`, `collect_to_with_first!`).
- Many JSON leaves are doubt in code at declared signature: `String(x)` with untyped `x` may truncate `Vector{UInt8}`.

## Doubt test split (`compare/doubt.py`)

Doubt test (`CLAUDE.md`, `docs/design/findings.md`) sends Corset limits to coverage line. Bar counts both kinds.

| Package | `possible` | Blind spot | Open dispatch | Doubt in code | Without blind spots | Bar |
|---|---|---|---|---|---|---|
| Distances | 86 | 0 | 47 | 39 | 30.4% | 38.7% |
| DataStructures | 417 | 186 | 97 | 134 | 15.9% | 28.6% |
| JSON | 213 | 63 | 120 | 30 | 27.2% | 30.4% |

- Blind spot: `alias`, candidate without summary. Upper bound: some `alias` merges come from unresolved calls.
- Open dispatch: too many candidates, unresolved splat. Dispatch is open in code; Corset did not examine every candidate.
- Doubt in code: candidates disagree, callee type unknown, unknown callable, unknown C call.

## Open decisions

- Field sensitivity: content class per field. Targets `alias` leaf; large engine change.
- Bar counts blind spots and doubt in code together; S5 baseline counted both too.
- Time: reuse `inference` stage IR for package instances; JSON analysis alone (4.93 s) still exceeds 3.3 s.

## Files

- `src/EffectSpike.jl`, `src/contracts.jl`: engine and contracts.
- `fixtures.jl`: `julia +1.13 --project=. fixtures.jl`; 116 tests. Modes: `S5_CONTRACTS=0`, `S5_PKGJOIN=0`, `S5_MUST=0`.
- `corpus.jl`, `run_trace.sh`: corpus run; `python3 score.py results repair2` prints table.
- `results/`: last corpus run (`repair2`), JSON warm-pass profile from run before repair fix.
- `compare/`: julia-anal runner, per-method kinds, join and doubt-split scripts.
