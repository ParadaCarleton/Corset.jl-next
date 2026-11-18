# Phase 5 plan

PR plan for `effects` and `lifecycle` stages and their rules. Design: `effects.md`, `stages.toml`. Phase exit: `plan.md`, phase 5 row.

### Order

| # | PR | Holds | Needs | Status |
|---|---|---|---|---|
| 1 | Engine core | Units, IR, origins, points-to, builtins, static calls, solve, soundness property | — | #232 |
| 2 | Call resolution | Foreign calls, callback records, join, Base contracts, open calls | 1 | 2a #234; 2b #235; 2c #237; 2d #238; 2e #239 |
| 3 | Engine limits | Compiler-effects shortcut, stand-in cuts, effect kinds, iteration starts, throw paths, call facts | 2 | 3a #240 |
| 4 | Summary cache | Library summary disk cache; package summaries in method store | 3 | — |
| 5 | Corpus go/no-go | Gate below; no rule PR before it passes | 4 | — |
| 6 | `bang-convention` | F53, F86 | 5 | — |
| 7 | Effect rules | F54, F55, F56, F58 | 5 | — |
| 8 | Alias rules | F48, F50, F51, F109 | 5 | — |
| 9 | Lifecycle facts | `lifecycle` stage | 5 | — |
| 10 | Lifecycle rules | F32, F33, F34, F39, F40, F41 | 9 | — |

- One PR per row. Status gets PR number at merge.
- Rows 6 to 9 can merge in any order after row 5.

### Every PR

- Work in jj workspace `.worktrees/<name>` from `main`; one bookmark per PR.
- Cover every new line; run mutation check on copy; add regression test per bug found.
- Pass Runic check, self-lint, `test/invalidation.jl` and full local suite before merge.
- Engine PR: no rule reads its facts yet. Tests call `Effects` API directly.
- Rule PR: UI case per footgun with positive, negative and fix case (`architecture.md`, Tests).

### 1 Engine core

Sound summaries for package units through builtins and static calls. Other calls stay open (step 7) until PR 2.

- `inference` stage keeps `TypedCode` of units it infers this run; `inference_facts` returns them to `Engine`.
- Until PR 4, `effects` run bypasses method store: stored unit has no typed code.
- `Engine` runs `effects` after `inference` when enabled rule reads `effects`. `FactSet` gains `effects` field.
- `src/Effects/`: units, IR, origins, points-to, builtins (call step 1), static calls (call step 3), solve.
- IR: copy unit code, then run passes until `CC: COMPACT_1`. Instance outside package: native inference first.
- Native inference abort on instance outside package: crash journal and relaunch skip instance; it gets open summary and blind spot.
- Solve: call graph over variants; SCCs from own iterative Tarjan; worklist inside component.
- Sum types with data (origin kinds, call outcomes) use Moshi `@data` (new dependency). Ordered enums stay EnumX (`types.md`, Sum types).
- Facts: verdict per method, parameter and global; cause spans; result aliases; blind spots by reason.
- Coverage reasons: `always throws on stand-ins`, incomplete method causes, `alias`.

Tests:

- Fixture package `test/effects/EffectsCases`: method per builtin transfer function, origin kind and path depth (1, 2, `deep`).
- Result alias fixtures: write through returned view of argument; write through returned global.
- Soundness property (Supposition.jl): generate inputs per fixture method; compare deep copies before and after call.
- Observed write without definite or `possible` write in summary fails property.

Done: every fixture gives expected verdict; property passes; every-PR bar met.
Measure on corpus: instances, time, memory, share of methods with `possible` write. Log numbers in history.

### 2 Call resolution

Resolve calls that PR 1 leaves open: steps 2, 4, 5, 6 and 7 of `effects.md`, Calls.
Stacked PRs: 2a foreign table, zero match, join; 2b Base contracts; 2c splat dispatch; 2d provenance; 2e callback records.
Open-call census after 2b set this order; callback records cover least. Ablation and census: history, "Phase 5 call resolution".

- Zero-match call throws `MethodError`: dead code.
- Foreign call table: `memmove`, runtime type queries. Unknown foreign call gives `possible` write.
- Callback record: static call on callable holding caller object. Caller applies callee accesses to its own objects.
- Join over at most 3 matching methods in package code. Disagreement gives `possible`. Library code keeps dispatch open.
- Base contract table holds documented behavior only. `iterate` on `Iterators.Stateful` gives `possible` write.
- Contract applies after join fails: library code and package dispatch over 3 methods. Contract verdict is closed-world.
- Open call: provenance decides finding, blind spot or nothing.

Tests:

- Fixture per step: closure, `Base.Fix1`, callable struct, `foreach` with writing closure.
- `f(x::Any) = setfield!(x, :n, 0)` keeps definite write.
- Open call on opaque argument gives blind spot only.

Measure: `possible` share per corpus package; methods per join; contract hits. Join limit 3 since 2a; keep it at least compiler `max_methods`.

### 3 Engine limits

Compiler effects for speed; stand-in cuts and effect kinds for correct verdicts.
Stacked PRs: 3a compiler-effects shortcut and claims; 3b stand-in cuts; 3c effect kinds; 3d throw paths and call facts.

- Shortcut: empty summary for instance with `effect_free`, `inaccessiblememonly`, `notaskstate` and result without reference.
- Skip shortcut when reached method outside Base carries effects override.
- Compaction deletes call with unused result when compiler effects allow. Keep calls whose callee carries effects override: false claim hides write.
- Cuts: `inference` stage finds units with dead call or store statements, then infers those at declared signature.
- Effect kinds and audited Base table (`effects.md`, Effect kinds).
- Throw paths: writes before throw stay. Calls that only build thrown value add nothing.
- Call facts: callee, kinds, may throw, result used or discarded.

Tests:

- Fixture per effect kind and per audited table entry.
- `x isa BigFloat && (STATE[] += 1)` gives `cut`.
- False `@assume_effects` in fixture dependency turns shortcut off.
- Caller of method with false `:effect_free` claim that drops result keeps write.
- `foreign_mutate!(x); error()` keeps write on `x`.

Measure: share of instances shortcut skips; time it saves.

### 4 Summary cache

- Library summaries: disk cache in Corset scratch space. Key: `effects.md`, Solve and cache.
- Package unit summaries: method store entry beside `Inferred`, same invalidation.

Tests: cache hit gives same summaries as cold run. Edit of path dependency, or other Julia version, changes key.
Measure: cold run with empty cache; cold run with cache from other corpus package; warm rerun.

### 5 Corpus go/no-go

Run engine on each corpus package (`plan.md`, Corpus). Every item holds per package:

- `possible` write on at most 30% of package methods with verdict; closures and keyword bodies count.
- Coverage line counts methods without verdict.
- Hand audit of 20 contract and join verdicts finds no false definite.
- With warm library cache, `effects` stage takes at most `inference` stage time.
- Full cold run with library cache from other corpus package stays inside speed budget.
- First run with empty library cache and cold Base cache build are measured.

Fail: revise call resolution, then run gate again. Log result in history; put timings in `plan.md` speed budget.

### 6 `bang-convention`

- F53 `missing`: method writes argument or global; name has no `!`. Decision flow: `effects.md`.
- F86 `spurious`: `!` method writes nothing on any path; callers drop its result.
- Method added to other module's `!` function: no rename fix. Writes nothing on any path: F86 finding, fix `manual`.
- F86 exempts `sizehint!` (hint) and `!!` functions (mutate when possible, else return new value).
- Definite write gives `definite` finding. `possible` findings stay off until quality gate passes.
- Fix: rename definition and package call sites.

### 7 Effect rules

- `unused-call` (F54): discarded call without effect of any kind, without throw, and with termination.
- `hidden-input` (F55): reads default RNG, task-local state, `ScopedValue` or mutable global.
- `impure-lambda` (F56): anonymous function captures mutable state.
- `false-effects` (F58): own analysis contradicts package `@assume_effects` claim.

### 8 Alias rules

Rules read per-unit statement events and must-alias pairs.

- `iteration-mutation` (F48): container written inside loop that iterates it.
- `self-alias` (F50): same container passed twice to writing call.
- `stateful-reuse` (F51): method restarts iterator whose type admits stateful iterator, or lets it escape after start.
  - Start: `iterate` without state, directly, through contract (`first`, generic `isempty`) or through callee summary.
  - Restart: second start of same object on one path. Loop re-entry counts; `zip(itr, itr)` counts.
  - Escape after start, or start after escape: return, store into object or global, operand of open call.
  - Parameter started once without escape: no finding. Summary records start, so caller sees its own restart.
  - Multi-pass types: `AbstractArray`, `AbstractDict`, `AbstractSet`, `AbstractString`, `Tuple`, `NamedTuple`, `Number`, `AbstractChar`.
  - Other abstract type admits stateful iterator. Concrete type is stateful when its `iterate` summary writes iterator or below it.
  - Definite when starts and escape are in method code and objects must-alias; on in default preset. Open call or may-alias gives `possible`.
  - Fix `manual`: `Iterators.peel`, thread `iterate` state, or narrow argument to multi-pass type.
- `stateful-iterate` (F109): `iterate` on `Iterators.Stateful`; suggest `popfirst!`. Reads inference facts only.

### 9 Lifecycle facts

- `lifecycle` stage builds def-use per array from allocation sites, events, must-alias pairs and escapes of `effects`.
- Callee reads and writes come from summaries. Array passed to callee that does not write it does not escape.
- Element events carry index operand; stage decides which elements writes cover.
- Definite facts need straight-line pattern. Branch join gives `possible`.

### 10 Lifecycle rules

`temporary-array` (F32), `unwritten-element` (F33, F34), `constant-array` (F39), `slice-copy` (F40), `broadcast-rebind` (F41). Split by rule if PR grows large.

### Phase end

- Codex adversarial review of whole phase diff. Brief holds design parts and `src/` only. Log findings in history.
- Run all phase 5 rules on corpus. Owner approves each upstream issue.
- Update `plan.md` phase 5 row and speed budget.

### Open decisions

Owner decides before PR that names decision:

- PR 3: lock writes. `lock(q.lk)` on argument writes lock state, so `bang-convention` would demand `!`. Proposal: exempt synchronization.
- PR 6: fix tier of rename. Proposal: `breaking` for public or exported name; `likely` for other names.
