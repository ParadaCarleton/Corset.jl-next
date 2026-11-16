# Spike P5: call resolution for write summaries

Verdict at stand-in signatures (`docs/design/types.md`): Distances and DataStructures pass. JSON misses `possible` bar by 13 methods and time bar by 3.2× (1.9× with `inference` stage IR).
Verdict at declared signatures (S5 baseline): Distances passes. DataStructures misses `possible` bar by 3 methods. JSON misses `possible` bar by 46 methods and time bar by 2.8×.

Engine is S5 engine (`spikes/s5-effect-summary`) plus call resolution. Signatures: `S5_ROOTS=declared` (S5 baseline) or `S5_ROOTS=standin`.

## Go/no-go (`docs/design/plan.md`, design reviews)

Stand-in signatures (run `standin5`):

| Package | Bar | `possible` | Without blind spots | Verdicts | Effects, warm | Package IR in warm | `inference` stage |
|---|---|---|---|---|---|---|---|
| Distances 0.10.12 | 38.7% | 22.6% (43/190) | 19.5% | 190/283 | 1.83 s | 0.88 s | 3.2 s |
| DataStructures 0.19.6 | 28.6% | 22.8% (296/1300) | 13.5% | 1300/1449 | 4.93 s | 2.39 s | 3.0 s |
| JSON 1.13.4 | 30.4% | 33.2% (151/455) | 24.6% | 455/553 | 10.67 s | 4.37 s | 3.3 s |

- Share counts methods with verdict. Over all methods: 15.2%, 20.4%, 27.3%.
- Package IR: `inference` stage infers same instances. Effects time without it: 0.95 s, 2.54 s, 6.30 s.
- Warm time varies up to 1.8× between runs; three packages share `ssh-dev`. DataStructures: 4.93–9.57 s.

Declared signatures (run `repair2`):

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

## Stand-in signatures (`S5_ROOTS=standin`)

- Roots: `Signatures.method_signatures` from rewrite `src/` (`corset_shim.jl`), at most 8 per method.
- Method with every argument `Any`: no root. Concrete package instances that analyzed callers reach give its verdict.
- Verdict: worst over root instances and reached concrete instances.
- Doubt split: blind spot 6, 120, 39; open dispatch 25, 75, 87; doubt in code 12, 101, 25.
- Method cause: highest doubt kind over its instances, so doubt in code in one instance makes finding.

Methods without verdict go to coverage line:

| Package | Unannotated, not reached | Always throws | Lossy | Failed |
|---|---|---|---|---|
| Distances | 47 | 32 | 14 | 0 |
| DataStructures | 82 | 41 | 26 | 0 |
| JSON | 77 | 17 | 3 | 1 |

- Always throws: every instance infers `Union{}`. Distances `_pairwise!` at `ArrayStandIn{Any, 2}` calls `zero(Any)`.
- Lossy: stand-in cuts path. Reachable call fails at stand-in, not at declared signature.
  - Analysis skips cut path as error path, so writes behind it are unseen.
  - First run gave 4 false none on `!` methods. `_minmax_heap_trickle_down!` passes `Int` and `IntStandIn` to `children_and_grandchildren(::T, ::T)`.
  - `Accumulator` `merge!` and `union!` at `Accumulator{Any, Any}` call `zero(Any)`.
  - Summary flag `lossy` passes to callers. Verdict none with flag goes to coverage line.
  - Struct stand-ins count as stand-ins: `Accumulator{Any, Any}` holds no `StandIns` type.
- Element `Any` (`Signatures.arrays`) and struct parameter `Any` cause most throwing and lossy methods.

`types.md` rule: argument without stand-in gives no findings from its data. Exact rule needs taint per argument; not done.

- Methods with argument without stand-in (implicit `Any` included): 169, 945, 411 (`bare_list.jl`).
- Non-blind `possible` in other methods: 8, 10, 17 (4.2%, 0.8%, 3.7%). This bounds the rule's effect.
- JSON top leaves at stand-ins: `String` too many candidates 44, alias 28, `setup_stdio` 19. `String(x)` takes `AbstractString` argument; no stand-in yet.

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

## Remaining `possible` at declared signatures (blame leaf of first write)

| DataStructures | n | JSON | n |
|---|---|---|---|
| alias | 186 | `String` too many candidates | 53 |
| type call `_` (`D(kv)`, `D` free) | 64 | alias | 47 |
| `_apply_iterate` unresolved | 22 | `setup_stdio` too many candidates | 19 |
| `map` too many candidates | 18 | `invoke_in_world` candidate without summary | 16 |
| type call `convert` | 15 | `substrides` too many candidates | 12 |

- `alias`: graph is field-insensitive and flow-insensitive. Unknown call result unifies with every operand, so unrelated classes merge (`grow_to!`, `collect_to_with_first!`).
- Many JSON leaves are doubt in code at declared signature: `String(x)` with untyped `x` may truncate `Vector{UInt8}`.

## Doubt test split at declared signatures (`compare/doubt.py`)

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

- Taint from argument without stand-in to `possible` write. Bound above: most JSON `possible` verdicts.
- Number element signature (`ArrayStandIn{FloatStandIn}`) when element `Any` instance throws or cuts path. Affects `inference` stage too.

- Field sensitivity: content class per field. Targets `alias` leaf; large engine change.
- Bar counts blind spots and doubt in code together; S5 baseline counted both too.
- Time: reuse `inference` stage IR for package instances; JSON analysis alone still exceeds 3.3 s (4.93 s declared, 6.30 s stand-in).

## Files

- `src/EffectSpike.jl`, `src/contracts.jl`: engine and contracts.
- `fixtures.jl`: `julia +1.13 --project=. fixtures.jl`; 122 tests. Modes: `S5_CONTRACTS=0`, `S5_PKGJOIN=0`, `S5_MUST=0`.
- `corpus.jl`, `package.jl`, `run_trace.sh`: corpus run; `python3 score.py results repair2` prints table.
- Stand-in run: `S5_ROOTS=standin TAG=standin5 ./run_trace.sh`. `CORSET_SRC` names rewrite `src/` (default `../../src`).
- `bare_list.jl`: methods with argument without stand-in, per package.
- `results/`: declared run `repair2`, stand-in run `standin5`, bare lists, JSON warm-pass profile from run before repair fix.
- `compare/`: julia-anal runner, per-method kinds, join and doubt-split scripts.
