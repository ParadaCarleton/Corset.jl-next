# Phase 5 plan

PR plan for `effects` and `lifecycle` stages and their rules. Design: `effects.md`, `stages.toml`. Phase exit: `plan.md`, phase 5 row.

### Order

| # | PR | Holds | Needs | Status |
|---|---|---|---|---|
| 1 | Engine core | Units, IR, origins, points-to, builtins, static calls, solve, soundness property | — | #232; frozen |
| 2 | Call resolution | Foreign calls, callback records, join, Base contracts, open calls | 1 | 2a #234; 2b #235; 2c #237; 2d #238; 2e #239; frozen |
| 3 | Engine limits | Compiler-effects shortcut, stand-in cuts, effect kinds, iteration starts, throw paths, call facts, release balance | 2 | 3a #240, 3b #241, throw paths #246, 3c #247, 3e #248, call facts #249 (fix #252), iteration starts #250, frame copy #253; frozen |
| 4 | Summary cache | Library summary disk cache; package summaries in method store | 3 | #251 (per-environment key), #254 (per-entry key); frozen |
| 5 | Name tier | `effects` stage on name trust and compiler effects; facts keep `MethodEffects` shape | — | — |
| 6 | Engine removal | Delete engine, library summary cache and their tests | 5 | — |
| 7 | `stateful-iterate` | F109 | — | — |
| 8 | Alias rules | F48, F50, F51 | 5 | — |
| 9 | Effect rules | F54, F55, F56, F58, F98 | 5 | — |
| 10 | `bang-convention` | F53, F86 | 5 | — |
| 11 | Lifecycle facts | `lifecycle` stage | 5 | — |
| 12 | Lifecycle rules | F32, F33, F34, F39, F40, F41 | 11 | — |

- One PR per row; split a rule row by rule when it grows large. Status gets PR number at merge.
- Rule rows merge in any order after row 5. Bug rules go first: F48, F50, F98, F58, F54.
- Rows 1 to 4 built the whole-program engine. Its code and design stay at tag `effects-engine` (history, "Engine freeze").

### Every PR

- Work in jj workspace `.worktrees/<name>` from `main`; one bookmark per PR.
- Cover every new line; add regression test per bug found. Mutation check on copy is optional.
- Pass Runic check, self-lint, `test/invalidation.jl` and full local suite before merge.
- Rule PR: UI case per footgun with positive, negative and fix case (`architecture.md`, Tests).
- Rule PR passes quality gate on corpus (`plan.md`). It waits for no other gate.

### 5 Name tier

Facts for every effects rule from each package method alone (`effects.md`, Name trust).

- `Engine` runs `effects` after `inference` when enabled rule reads `effects`. Name tier replaces engine call in `effects_facts`.
- Facts keep `MethodEffects`, `Access`, `CallFact` and `UnguardedHold`, so rules of local effect-rules stack port.
- Fields name tier never fills (`blind_writes`, `blind_reads`, `closed_world`) leave in row 6.
- Tables: written operand position, alias, exception, consuming, release primitives. Each entry cites Base docstring or style guide.
- Method store keeps unit record; same record format as engine (`records.jl`).

Tests:

- Fixture package `test/effects/EffectsCases`: method per write source, table entry and kind; closure capture; release primitive.
- Soundness property on fixtures that follow convention: observed write needs fact.

Done: every fixture gives expected facts; property passes; every-PR bar met.
Measure on corpus: `effects` stage time against `inference` stage; methods with write fact; `possible` share.

### 6 Engine removal

- Delete engine files, library summary cache, crash relaunch for library instances, and their tests.
- Keep crash journal that `inference` stage reads.
- Tag `effects-engine` at last main commit with engine.

### 7 `stateful-iterate`

- F109: `iterate` on `Iterators.Stateful`; suggest `popfirst!`. Reads inference facts only.

### 8 Alias rules

Rules read per-unit statement events and must-alias pairs.

- `iteration-mutation` (F48): container written inside loop that iterates it. Alias-table result counts: `keys(d)` iterates `d`.
- `self-alias` (F50): same container passed as written operand and as other operand of `!` call.
  - Exempt: functions that unalias operands (`copyto!`, `broadcast!`, `materialize!`).
  - Definite for function whose docstring warns of shared memory ("Behavior can be unexpected when any mutated argument shares memory"). Else `possible`.
- `stateful-reuse` (F51): method restarts iterator whose type admits stateful iterator, or lets it escape after start.
  - Start: `iterate` without state, contract start (`first`, generic `isempty`) or consuming-table call.
  - Restart: second start of same object on one path. Loop re-entry counts; `zip(itr, itr)` counts.
  - Escape after start, or start after escape: return, store into object or global, operand of package call.
  - Parameter started once without escape: no finding.
  - Multi-pass types: `AbstractArray`, `AbstractDict`, `AbstractSet`, `AbstractString`, `Tuple`, `NamedTuple`, `Number`, `AbstractChar`.
  - Other abstract type admits stateful iterator. Concrete library type: exception table decides.
  - Definite when starts and escape are in method code and objects must-alias; on in default preset. May-alias gives `possible`.
  - Fix `manual`: `Iterators.peel`, thread `iterate` state, or narrow argument to multi-pass type.

### 9 Effect rules

Port rules of local effect-rules stack onto name-tier facts.

- `unused-call` (F54): discarded call that compiler proves `effect_free`, `nothrow` and terminating.
- `hidden-input` (F55): reads default RNG, task-local state, `ScopedValue` or mutable global.
- `impure-lambda` (F56): anonymous function captures mutable state.
- `false-effects` (F58): write and read events contradict package `@assume_effects` claim.
- `unguarded-release` (F98): effects version reads hold counts; delete syntax version in same PR.

### 10 `bang-convention`

- F53 `missing`: method writes argument or global; name has no `!`. Decision flow: `effects.md`.
- F53 also reports library-function methods that write an argument without `!`: name trust depends on them.
- F86 `spurious`: `!` method writes nothing on any path; callers drop its result.
- F86 is definite only when compiler proves `effect_free` for every unit. Else name-trust none gives `possible`.
- Method added to other module's `!` function: no rename fix. Writes nothing on any path: F86 finding, fix `manual`.
- F86 exempts `sizehint!` (hint) and `!!` functions (mutate when possible, else return new value).
- Definite write gives `definite` finding. `possible` findings stay off until quality gate passes.
- Fix: rename definition and package call sites.

### 11 Lifecycle facts

- `lifecycle` stage builds def-use per array from allocation sites, events, must-alias pairs and escapes of `effects`.
- Callee reads and writes come from names: `!` call writes its written operand; other call reads operands.
- Element events carry index operand; stage decides which elements writes cover.
- Definite facts need straight-line pattern. Branch join gives `possible`.

### 12 Lifecycle rules

`temporary-array` (F32), `unwritten-element` (F33, F34), `constant-array` (F39), `slice-copy` (F40), `broadcast-rebind` (F41). Split by rule if PR grows large.

### Phase end

- Codex adversarial review of whole phase diff. Brief holds design parts and `src/` only. Log findings in history.
- Run all phase 5 rules on corpus. Owner approves each upstream issue.
- Update `plan.md` phase 5 row and speed budget.

### Open decisions

Owner decides before PR that names decision:

- Row 10: fix tier of rename. Proposal: `breaking` for public or exported name; `likely` for other names.
