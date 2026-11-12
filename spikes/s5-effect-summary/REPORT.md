# Spike S5: write summary per method

Verdict: works with limits. Own summary on optimized typed IR (Julia 1.13.3) gives correct definite writes on corpus. `possible` is too broad to report until dynamic dispatch resolves.

## Design

- Per method instance: Steensgaard points-to graph (union-find, one content class per class), flow-insensitive.
- Classes carry source tags: parameter index, global key, `:fresh`, `:unknown`, `:maybe`.
- Summary per instance (`src/EffectSpike.jl` `Summary`):
  - per parameter: write to top object, write to inner reach, result within parameter, result holds parameter;
  - stores and merges between parameters;
  - globals written, and globals written directly;
  - result aliases global;
  - `opaque` flag;
  - `fresh_result`.
- Certainty: definite when write target must derive from one parameter or global (base chain or pure source set); otherwise possible.
- Calls:
  - `:invoke` applies callee summary.
  - Dynamic `:call` joins summaries of up to 4 `_methods_by_ftype` candidates at their declared signatures. Definite only when one candidate exists or all candidates agree.
  - Else unknown: deep possible write on every operand, result aliases operands, `opaque`.
- Bottom-up: recursive Tarjan over discovered instances; each SCC iterates `lub` to fixpoint. IR is kept only for SCCs in progress.
- Skips:
  - blocks that always reach `unreachable` (error paths);
  - writes to objects still pure-fresh when written (sound at argument and global level, because exposing them is itself a recorded write);
  - `Task` and `Regex` targets;
  - write-once lazy init (`setfieldonce!`, `replacefield!` from `nothing`).
- Report-time classes:
  - parameter declared `IO` or `AbstractRNG`;
  - global holding `IO`, RNG, `Task` or lock;
  - memo: package global, not public, one direct writer;
  - foreign-module global (counted apart, not reported).

## Fixtures

`julia +1.13 --project=. fixtures.jl`: 23/23 pass in 0.3 s.

- Alias via view: inlined and `@noinline` callee, both definite.
- Write through closure: inlined is definite; through `@noinline` higher-order call is definite.
- Write through struct field: definite.
- Recursive pair `ping`/`pong` (SCC): both definite.
- Negatives: `copy` then write; `Ref(a)` wrapper write; broadcast with `unalias` (`x .- sum(x; dims=1)`); read only.
- Globals: `push!` on const global: definite; write through returned global (`getreg()`): definite; typed non-const global: definite; untyped global: possible (dynamic `setindex!`); fresh result holding global: at least possible.
- Exemption inputs: IOBuffer argument write: definite, then IO class; RNG argument: definite, then RNG class; `rand()` global RNG: no write (task state); memo `get!`: definite, then memo class; `LazyString` read: lazy init.
- Possible-alias regression: `maybe_alias(x, flag) = flag ? x : copy(x)`, then caller writes result. Possible, not definite.

## Corpus

Command: `spikes/s5-effect-summary/run_all.sh`. Raw output is in `results/<pkg>[-standin].txt` and flags in `results/<pkg>[-standin]-flags.tsv`.

Modes:
- `declared`: method signature as written, type variables free.
- `standin`: crude concrete substitution (Float64, Vector{Float64}, Int, String, IOBuffer). S1 replaces it.

Counts are methods. `plain` names have no `!`; `generated` names start with `#`. A plain name with definite writes is a missing `!`; a bang name with no writes is a spurious `!`.

| Package | mode | methods | plain def / poss / none | bang def / poss / none | instances | SCC max | unknown calls | resolved dynamic | unknown foreign |
|---|---|---|---|---|---|---|---|---|---|
| Distances 0.10.12 | declared | 283 | 0 / 165 / 63 | 0 / 48 / 0 | 1084 | 4 | 4020 | 2507 | 286 |
| Distances | standin | 283 | 0 / 149 / 79 | 26 / 22 / 0 | 1157 | 4 | 2710 | 1597 | 278 |
| DataStructures 0.19.6 | declared | 1449 | 10 / 690 / 360 | 227 / 103 / 1 | 2433 | 5 | 5046 | 5392 | 322 |
| DataStructures | standin | 1449 | 9 / 670 / 374 | 177 / 152 / 1 | 2691 | 5 | 7716 | 5249 | 498 |
| JSON 1.13.4 | declared | 553 | 6 / 249 / 180 | 12 / 40 / 0 | 2436 | 18 | 8187 | 7259 | 1316 |
| JSON | standin | 553 | 5 / 232 / 192 | 10 / 42 / 0 | 2422 | 18 | 8474 | 6966 | 1270 |

Definite missing `!`, all checked by hand, all real writes:
- DataStructures: splay-tree `haskey` and `in` (splaying); `in_same_set` (path compression); AVL and red-black rotations, `rb_transplant`, `delete_fix`, `insert_node`; `iterate(::OrderedRobinDict)` (lazy rehash); `iterate(pq, state)` (`popfirst!` on state).
- JSON: `Object(obj, k, v)` sets `obj.child`; `_contextmake` saves and restores `st.context.failure`; `_writenested` pushes ancestor stack; `Base.deepcopy_internal` writes `stackdict` (Base API name).
- Some are policy questions (write then restore, Base-owned names, lazy rehash), not analysis errors.

Spurious `!`: `pop!(::SortedSet) = error(...)`. It is true by rule, but error-only methods need exemption.

False definites found and fixed during spike. Each has a regression fixture:
- `getfield` of pointer field modeled as content: memmove into copy hit source.
- Callee results lost freshness (`reducedim_initarray`).
- `within` was definite when only one return was the parameter.
- Possible alias merged classes without marker, so source sets promoted writes to definite. Marker must propagate to content classes.
- Base lazy caches: `Regex` compile, `LazyString.str`.

Blockers of definite, from the plain `possible` methods:
- `opaque` is true for 165/165 (Distances), 690/690 (DataStructures) and 248/249 (JSON).
- Every possible-only verdict traces to an unknown callee or unknown foreign call, not to alias imprecision.
- Unknown calls per package: 4020 to 8474, against 1597 to 7259 dynamic calls resolved through at most 4 candidates.
- Main sources: untyped or abstract arguments (`(dist::M)(a, b)`, `colwise(metric, a, b)`); more than 4 candidates (`getindex`, `setindex!` on `AbstractArray`); non-constant callee (`f(x)` with `f::Function`).
- Top unknown foreign calls: `jl_get_world_counter`, `jl_eval_globalref`, GMP, PCRE, `jl_symbol_name`, BLAS `cblas_ddot64_`.
- Stand-ins move Distances bang methods from 0 to 26 definite. They do not move plain possible much, because most writes reach untyped arguments.

## Cost

- Quiet host, declared mode: Distances 17 s summary (5 s IR, 1084 instances); DataStructures 22 s (7 s IR, 2433 instances).
- Loaded host (four other spike agents), same instance counts: Distances 118 s, DataStructures 150 s, JSON 200 s.
- IR is about 40% of time. The rest is analysis plus `_methods_by_ftype` candidate lookups, and JIT of spike code.
- Instances per package method: 3.8 (Distances), 1.7 (DataStructures), 4.4 (JSON). Most are Base callees shared across packages.
- Memory: max RSS 800-860 MB per run, including package load.
- SCCs are small: max 4, 5 and 18; 1.7 to 1.8 fixpoint iterations per SCC.
- First failure mode: specializing dynamic candidates on call-site types grows signatures without bound (`ComposedFunction{ComposedFunction{...}}`, vararg `broadcasted(::Any...)`). It reached a Tarjan depth over 10,000 and never finished. Candidates must use declared signatures (`candidate_instances`).

## Core.Compiler internals used (pin per Julia minor)

- `Core.Compiler.typeinf_ircode(NativeInterpreter(), mi, nothing)`: optimized IR per instance.
- `Core.Compiler.argextype`, `widenconst`, `singleton_type`, `get_ci_mi`, `specialize_method`.
- `IRCode`: `stmts.stmt`, `argtypes`, `cfg.blocks[i].stmts`, `.succs`.
- `Base._methods_by_ftype(tt, limit, world)`, `Base.specialize_method`, `Base.visit(f, Core.methodtable)`.
- IR shapes: `:invoke` with `CodeInstance` first argument (changed in 1.12); `:foreigncall` layout (`args[3]` svec, `args[6:5+n]`); `PhiNode`, `PhiCNode`, `UpsilonNode`, `PiNode`, `ReturnNode` without `val`.
- Builtin lists: field, memory and global write builtins; `memorynew`, `memoryrefnew`, `compilerbarrier`; dynamic builtins (`_apply_iterate`, `invoke_in_world`, `_call_in_world_total`, `_call_latest`). `Core._call_within` is gone in 1.13; the list broke on first load.
- C function table (`FOREIGN`): runtime names (`jl_genericmemory_copy_slice`, `jl_eqtable_put`, scheduler calls). These drift per version.
- Not tested on 1.12 or 1.14-alpha. Expect the builtin and C name tables to need edits per minor.
- Compiler `EscapeAnalysis` is not used. It has no interprocedural return-alias or field-store summary, which the design needs.

## Gaps

- Context-insensitive: one summary per instance. Const-prop-pruned branches still count.
- Write before a caught throw is lost (error-path skip).
- Parameter stored into global is not tracked (escape to global).
- Pointers from integers taint the class; writes through them only set `opaque`.
- Unknown callee does not imply unknown global write. `opaque` records it, unreported.
- Steensgaard source tags are fiddly. Definite attribution needs a must-alias layer; tag propagation bugs produced every false definite above.
- Kwarg bodies and closures (`#f#12`) are counted under `generated` and not mapped to their function name.

## Contradictions with design

- `effects.md:10` "Is every written object IO?": IO writes land in `Memory` buffers. The class must come from parameter or global type, not object type.
- `effects.md:10-14` lacks lazy-init caches (`Regex`, `LazyString`, `setfieldonce!`), task-local state, locks and foreign-module globals. Base logging and path code writes about 13 foreign globals per package (`Base.PCRE.THREAD_MATCH_CONTEXTS`, `Base.CoreLogging._global_logstate`).
- `effects.md:22` "escape analysis inside method": compiler EA is unsuitable; own points-to used.
- `effects.md:22` and `plan.md:24` "callee summaries at calls" conflict with `principles.md:21` and `CLAUDE.md:19` "never analyze dependency code, Base included".
- `plan.md:31`: possible tier fails 90% precision without dispatch resolution. About 100% of possible verdicts come from opaque calls.
- `plan.md:36` speed budget: Base callee summaries dominate. They need a per-Julia-version cache to fit.
- Footgun 86 (`footguns.toml:536`): error-only bang methods need exemption.

## Engine contract for Corset facts

Any engine must expose per method instance:
- Write certainty per parameter (definite, possible, none), split into top object and reachable objects.
- Globals written, keyed by binding (module, name), each with certainty and a direct or propagated flag. The memo rule needs the direct flag.
- Result aliasing: within parameter, holds parameter, aliases global, fresh.
- Parameter-to-parameter stores and merges, so callers can compose.
- Opaque reasons with counts: unknown callee (non-constant, too many candidates, inference failure), foreign call name, untracked pointer. This drives the coverage line and analysis gaps.
- Write site for each definite write (statement index, mapped to a span through S2) and the callee chain for cause spans.
- Exemption hooks: target types (IO, RNG, Task, locks, lazy-init types), write-once field writes and foreign-module globals, kept apart from reported writes.
- Bounded candidate policy for dynamic calls at declared signatures, plus a stand-in signature entry point from S1.
- Cacheable summaries keyed by method instance and world, with Base summaries shareable across packages.

## Reproduce

```
cd spikes/s5-effect-summary
JULIA_NUM_THREADS=2 julia +1.13 --project=. fixtures.jl
./run_all.sh
S5_STANDIN=1 JULIA_NUM_THREADS=2 julia +1.13 --project=. -e 'include("corpus.jl")' DataStructures
```
