# Effects

`!` convention and effect facts.

`!` marks every function that can change state outside itself, IO excepted. When behavior is inconsistent, `!` names functions where bug can be.

<div class="flow" role="img" aria-label="Decision steps for whether a function needs a bang">
      <div class="q"><div class="ask">Does method write memory caller can see?<small>Corset write facts per method</small></div><div class="out">no → no <code>!</code></div></div>
      <div class="down">yes ↓</div>
      <div class="q"><div class="ask">Is every write through IO?<small>argument or global declared <code>IO</code>: <code>stdout</code>, files, logging. Decide by declared type; IO writes land in plain <code>Memory</code> buffers</small></div><div class="out">yes → no <code>!</code></div></div>
      <div class="down">no ↓</div>
      <div class="q"><div class="ask">Is only write advance of RNG?<small>any <code>AbstractRNG</code>: global, task-local or argument</small></div><div class="out">yes → no <code>!</code></div></div>
      <div class="down">no ↓</div>
      <div class="q"><div class="ask">Is only write cache with cheap proof?<small>known memo macro, or one owner method and non-public binding</small></div><div class="out">yes → no <code>!</code></div></div>
      <div class="down">no ↓</div>
      <div class="q"><div class="ask">Writes argument, global, or result that aliases global state</div><div class="out bad">require <code>!</code></div></div>
    </div>

- Known memo forms: `@memoize` (Memoize.jl, Memoization.jl), `@cached` (Caching.jl), `get!` on LRUCache.jl `LRU`.
- Other caches need opt-out comment with reason. Do not invest in deep invisibility proofs.
- Same cache exemption applies to `hidden-input`: cache read is invisible to caller.
- Callee name is write evidence (Name trust). Argument order tells which argument changes.
- Requirement propagates: caller of `!` function on its argument or global state needs `!` too.

### Name trust

`effects` stage reads each package method alone. Callee names and compiler effects stand in for callee bodies.
Code lives in `src/Effects/`.

<div class="pipeline" role="img" aria-label="Effects stage steps from inference stage units to effects facts">
      <div class="layer"><div class="id">units</div><div class="what">Method and stand-in signature, from <code>inference</code> stage<small>same signatures · no own roots · no inference</small></div></div>
      <div class="layer"><div class="id">IR</div><div class="what">SSA IR before inlining, from unit's typed code<small>passes until <code>CC: COMPACT_1</code> · statement flags keep compiler effects</small></div></div>
      <div class="layer"><div class="id">roots</div><div class="what">Caller-visible object each value can hold<small>parameter, global, fresh · alias table for call results</small></div></div>
      <div class="layer"><div class="id">events</div><div class="what">Writes, reads, starts, holds per statement<small>builtin stores · <code>!</code> names · exception table · closures</small></div></div>
      <div class="layer"><div class="id">facts</div><div class="what">Worst over units of method<small>facts for rules and <code>lifecycle</code></small></div></div>
    </div>

- Name trust: a public function writes an argument only when its name ends in `!`, as Julia style guide asks.
- A callee that breaks the convention is a bug in its own package. `bang-convention` reports it there.
- Cost: a write through a non-`!` function that breaks the convention stays unseen in its callers.
- Whole-program engine (points-to through Base) is frozen at tag `effects-engine` (history, "Engine freeze").
- Revive the engine only when name-trust misses block the quality gate of a rule.

#### Units and IR

- Effects reads units of `inference` stage: method and stand-in signature, plus signatures package calls reach.
- IR: copy unit's unoptimized typed code; run compiler passes until `CC: COMPACT_1`. No callee gets IR.
- Statement flags from inference give compiler effects per call: `effect_free`, `nothrow`, `terminates`, `consistent`.
- Method gets facts from its units only. Verdict of method: worst over its units.
- Incomplete method (`inference` stage `incomplete`) gets no definite none. Coverage reason names cause.
- Method store entry keeps effects record of unit beside `Inferred`, same invalidation. Stored unit needs no typed code.

#### Roots

Each SSA value gets a set of roots: the caller-visible objects it can hold or lie beneath.

- Root: parameter, global binding, or fresh. Fresh objects are local: writes to them are no facts.
- Path: field name or element below root. Path collapses to `deep` past 8 steps.
- `getfield`, `getproperty` with constant name and `getindex` add a step to roots of their first operand.
- Phi and pi nodes join roots of their values.
- Alias table: library functions whose result can lie beneath an operand. Result takes `deep` place of that operand.
  - Table: `view`, `reshape`, `vec`, `parent`, `transpose`, `adjoint`, `keys`, `values`, `pairs`, `first`, `last`, `only`, `something`, `convert`, `identity`, `Ref`, `skipmissing`, iterator wrappers (`zip`, `enumerate`, `Iterators.*`).
  - Constructor result can hold its operands.
- Result of other call is fresh: Base documents each function whose result shares memory with an operand.
- Result of package call is fresh. Later: package record keeps result roots, and callers map them.
- Result with `isbitstype` type holds no root.

#### Writes

Write sources, in order:

1. Builtin store: `setfield!`, `setglobal!`, `memoryrefset!`, `swapfield!`, `modifyfield!`, `replacefield!`, `setfieldonce!`. Definite write on roots of target.
2. Call to function whose name ends in `!`. Written operand follows Julia style guide argument order:
   - Skip leading callable (`Function`, `Type`), `IO` and `AbstractRNG` operands. First other operand is written: definite.
   - Skipped `IO` operand takes IO write; skipped `AbstractRNG` operand takes RNG argument write.
   - No operand left: definite write on unknown global state (`Random.seed!()`).
   - Position table holds exceptions: `ldiv!(A, B)` and `lmul!(A, B)` write `B`.
   - `!` call stores its other operands into written operand: `push!(v, x)` puts `x` into `v`.
3. Exception table: library functions without `!` that write. Iteration of stateful types (`Iterators.Stateful`, `Channel`, `EachLine`), IO functions on `IO` operand, locks and conditions, tasks, RNG functions, `finalizer`.
4. Foreign call: `possible` write on roots of pointer and object operands.
5. Closure built in method (`new` of closure type): its writes through captured fields map onto captured operands, with their certainty.
6. Other call: no write. Call of function value without name (callable argument or field) writes nothing too: Base names higher-order functions without `!` (`map`, `foreach`).

- Value with more than one root gives `possible` write on each root: branch decides which object changes.
- Write in package code keeps certainty on every root: `f(x::Any) = setfield!(x, :n, 0)` writes `x`.
- Writes before throw stay. Writes to fresh objects inside error paths are local.
- Compiler `effect_free` on unit proves no write: definite none. Else no write event gives none by name trust: at most `possible` none.

#### Reads

- Load of global binding: read of global. Constant binding of mutable type counts; constant of immutable type does not.
- `getfield` and `getproperty` read roots of their first operand. Every call reads roots of its operands.
- RNG function without `AbstractRNG` operand: default RNG read and write.
- `ScopedValue` read: `getindex` on `ScopedValue` or `ScopedValues.get`. Task-local state: `task_local_storage`, `current_task` fields.
- Iteration start: `iterate` without state, `first`, `only`, generic `isempty` and destructuring start their operand.
- Consuming table: library functions that iterate their operand (`collect`, `sum`, `map`, `filter`, `foreach`, `reduce`, `any`, `all`, `count`). Call starts its iterator operand.

#### Effect kinds

Facts keep every effect with its kind. Rules apply exemptions.

- Kinds: memory write, IO, default RNG, RNG argument, task-local state, `ScopedValue` read, lock and other synchronization, lazy init, iteration start.
- `bang-convention` exempts IO, RNG and lazy init. `unused-call` counts every kind. `hidden-input` reads default RNG, task-local state, `ScopedValue` and mutable globals.
- Kind comes from types along place path, root first: first `IO` gives IO, `AbstractRNG` gives RNG argument.
- Lock, `Condition` and `Semaphore` on path give synchronization. Path without such type gives memory write.
- Package `setfieldonce!` and package caches follow memo-cache rule above: cheap proof or opt-out.

#### Release balance

Facts keep hold count per resource at normal exit and at each statement that may throw.

- Primitive table: `lock`, `unlock`, `trylock` on lock; `acquire`, `release` on `Semaphore`; `open` with `IOStream` result; `close` on `IOStream`.
- `lock(f, l)`, `open(f, path)` and `@lock l expr` release in `finally`, which dataflow balances.
- Resource: one root of operand. Operand with several roots gives unknown count.
- Dataflow over CFG blocks, at most 4 paths per block. Branch on condition that path took before takes same side.
- Statement may throw when compiler `nothrow` is off. Inside `try`, it has an edge to its catch block.
- Call that passes held resource to other function makes count unknown: helper can release it.
- F98 fact: statement may throw outside every `try` while method holds resource. Exact count gives definite; unknown gives `possible`.
- Helper that acquires (`hold!(q) = lock(q.lk)`) stays unseen: its caller gets no fact.
- `trylock` gives unknown count.

#### Compiler effects

- Compiler effects come free with unit inference.
- `unused-call` (F54) needs compiler proof: discarded call with `effect_free`, `nothrow` and `terminates`. Name trust never proves none for it.
- `@assume_effects` makes compiler trust a claim. Call to package method with claim takes no proof from its flags.
- Claim deeper in callees stays unseen. `false-effects` reports a false claim in package that owns it.
- `false-effects` compares claims of package methods with their own write and read events.

#### Facts

- Per package method: `MethodEffects` with writes and reads by place, certainty and cause span; result aliases; holds; call facts; claims.
- Per call statement: callee, kinds of its writes, may throw, terminates, result used or discarded (F54, F86).
- Use counts before compaction: compaction turns each use of constant result into literal.
- Units of method merge by source statement: unit that may throw, writes or uses result decides.
- Per unit, for `lifecycle` and statement rules (F48, F50, F51): allocation sites, read, write and start events per statement in control-flow order, must-alias pairs, escapes.
- Must-alias: two values with same single root and path, where root is one object per call (parameter, global, allocation outside loop).
- Escape: return; store into object or global; operand of `!` call that is not the written operand; operand of alias-table call or constructor whose result escapes.
- Element event carries index operand: constant or SSA value. `lifecycle` decides which elements writes cover (F33, F34).

#### Tests

- Fixture per write source, alias table entry, position exception, exception table entry, closure capture and release primitive.
- Soundness property (Supposition.jl) on fixtures that follow convention: observed write needs definite or `possible` fact.
- Speed: `effects` stage at most 0.25 times `inference` stage on corpus (`plan.md`, speed budget).

### `!` scope

Argument and global writes. IO and RNG exempt. Memo caches exempt with cheap proof only.

### Borrow checking

Defer. Revisit for concurrency rules.
