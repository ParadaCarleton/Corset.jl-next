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
- Load from fresh object gives roots it holds. Nested fresh objects flatten: outer object holds roots that inner objects hold.
- Fresh object can also hold untracked objects: fresh, or unknown. Load from such object can be fresh, so writes through it are `possible`.
- Mutable literal in code, such as interpolated object, is global state: `Elsewhere` root.
- Phi and pi nodes join roots of their values.
- Alias table: library functions whose result can be an operand or lie beneath it. Result keeps places of each non-callable operand.
  - Table: `view`, `reshape`, `vec`, `parent`, `transpose`, `adjoint`, `keys`, `values`, `pairs`, `first`, `last`, `only`, `identity`, `skipmissing`, iterator wrappers (`zip`, `enumerate`, `Iterators.*`).
  - Pointer conversions before foreign call: `pointer`, `cconvert`, `unsafe_convert`.
- Choice table: result is one of the operands, callable objects included, so it joins their values: `something`, `coalesce`, `max`, `min`, `ifelse`.
- `convert` result is its operand, or new object as for other call.
- `typeassert` result is its operand. Lowering adds `typeassert` on each return of method with return type.
- Constructor, tuple and vector literal results hold their operands: `Ref(x)` holds `x`. Literal (`[x]`, `T[x]`) converts element not of its element type, so it can hold new object. Package method on literal syntax (`SA[x]`) is package call.
- Iteration: result of `iterate` and `indexed_iterate` holds element of iterated operand. Element step for array, dictionary, set and tuple; `deep` for other iterator.
- Element table: result is element of container operand, or other operand (`get(d, k, default)`).
  - Table: `get`, `get!`, `getkey`, `pop!`, `popfirst!`, `popat!`, `maximum`, `minimum`, `reduce`, `foldl`, `foldr`, `rand`, `take!`, `fetch`.
  - Container: first operand, or second after leading callable or `AbstractRNG` (`get(f, d, k)`, `rand(rng, xs)`).
  - Lookup default: third operand of `get`, `get!`, `getkey`, `pop!`, `popat!` without leading callable.
  - Result of leading callable can be fresh, or object it captures. `rand` with dimensions gives new array of elements.
  - Keyword call can give new array of elements (`dims`) or keyword value (`init`).
  - `take!` and `fetch` give element of `Channel`. Other result lies beneath operand or is new: `take!(::IOBuffer)` can share buffer.
- Result of other call, package call included, is fresh. It can hold untracked objects, and `deep` place of each operand whose type can hold pointing objects (`copy`, `filter`).
- Result that is package call operand, or lies beneath it, needs package record of result roots. Later: callers map them.
- Result with `isbitstype` type holds no root. Result whose type holds no pointing object holds no root inside.

#### Writes

Write sources, in order:

1. Builtin store: `setfield!`, `setglobal!`, `memoryrefset!`, `swapfield!`, `modifyfield!`, `replacefield!`, `setfieldonce!`. Definite write on roots of target. Pointer store intrinsics (`pointerset`) write target or below.
2. Call to function whose name ends in `!`. Written operand follows Julia style guide argument order:
   - Skip leading callable (`Function`, `Type`), `IO` and `AbstractRNG` operands. First other operand is written: definite.
   - Skipped `IO` operand takes IO write; skipped `AbstractRNG` operand takes RNG argument write.
   - No operand left: `possible` write on keyword values (`f!(; items)`); without keywords, definite write on unknown global state (`Random.seed!()`).
   - Position table holds exceptions: `ldiv!(A, B)` and `lmul!(A, B)` write `B`.
   - `!` call stores its other operands into written operand: `push!(v, x)` puts `x` into `v`. Later load from `v` can give `x`, also when `v` is caller place.
3. Exception table: library functions without `!` that write. Iteration of stateful types (`Iterators.Stateful`, `Channel`, `EachLine`, `Iterators` wrappers of them), IO functions on `IO` operand, locks and conditions, task switches, RNG functions.
   - `first`, `only` and consuming table on stateful iterator write it or below. `Iterators.flatten` of stateful iterators consumes them.
4. Foreign call: `possible` write on roots of pointer and object operands.
5. Closure built in method (`new` of closure type): call that can invoke it writes through captured fields onto captured operands, with their certainty.
   - Invoking calls: direct call, and function that calls its function arguments (`foreach`, `map`, leading callable of `!` call).
   - Builtins, constructors, tuples, alias functions and stored operands of `!` calls never invoke it. Closure that only escapes writes nothing in its builder.
   - Call that compiler proves `effect_free` runs no closure that writes caller state (`hash(f)`). `@assume_effects` in method or its callee voids that proof.
6. Other call: no write. Call of function value without name (callable argument or field) writes nothing too: Base names higher-order functions without `!` (`map`, `foreach`).

- Value with more than one root gives `possible` write on each root: branch decides which object changes.
- Write in package code keeps certainty on every root: `f(x::Any) = setfield!(x, :n, 0)` writes `x`.
- Writes before throw stay. Writes to fresh objects inside error paths are local.
- Compiler `effect_free` on unit proves no write: definite none. Else no write event gives none by name trust: at most `possible` none.
- Stand-in signature gives no proof: compiler effects describe stand-in only. `@assume_effects :effect_free` on method, block in it, or direct callee gives none either.
- Code coverage voids `effect_free` of tracked files: inference counts coverage counters as effects. Tests of proof rules run with coverage off.

#### Reads

- Load of global binding: read of global. Constant binding of mutable type counts; constant of immutable type does not.
- Facts keep reads of globals, special kinds and iteration starts. Plain argument loads stay out: every call reads its operands.
- RNG function without `AbstractRNG` operand: default RNG read and write.
- `ScopedValue` read: `getindex` on `ScopedValue` or `ScopedValues.get`. Task-local state: `task_local_storage`, `current_task` fields.
- Iteration start: `iterate` without state, `first`, `only` and destructuring start their operand. Generic `isempty` starts it when inferred `isdone` result can be `missing`.
- Consuming table: library functions that iterate their operand (`collect`, `sum`, `map`, `filter`, `foreach`, `reduce`, `any`, `all`, `count`). Call starts its iterator operand, and writes stateful iterator operand.

#### Effect kinds

Facts keep every effect with its kind. Rules apply exemptions.

- Kinds: memory write, IO, default RNG, RNG argument, task-local state, `ScopedValue` read, lock and other synchronization, lazy init, iteration start.
- `bang-convention` exempts IO, RNG and lazy init. `unused-call` counts every kind. `hidden-input` reads default RNG, task-local state, `ScopedValue` and mutable globals.
- Kind comes from types along place path, root first: first `IO` gives IO, `AbstractRNG` gives RNG argument.
- Lock, `Condition` and `Semaphore` on path give synchronization. Path without such type gives memory write.
- Package `setfieldonce!` and package caches follow memo-cache rule above: cheap proof or opt-out.

#### Release balance

Facts keep hold count per resource at normal exit and at each statement that may throw. Lands with F98 (`phase5.md`, row 8).

- Primitive table: `lock`, `unlock`, `trylock` on lock; `acquire`, `release` on `Semaphore`; `open` with `IOStream` result; `close` on `IOStream`.
- `lock(f, l)`, `open(f, path)` and `@lock l expr` release in `finally`, which dataflow balances.
- Resource: one caller place of operand, else IR value under `π` nodes. Value live into catch block names its `try` value.
- Dataflow over CFG blocks, at most 4 paths per block. Branch on condition that path took before takes same side.
- Join of paths with equal counts drops conditions they disagree on. Branch that can depend on dropped condition makes later facts `possible`.
- Dependence: dropped value, `φ` node, call without `:consistent` proof, or non-constant global, through operands.
- Statement may throw when compiler `nothrow` is off. Inside `try`, it has an edge to its catch block.
- Call that passes held resource to package function makes count unknown: helper can release it.
- Holder of fresh resource value hands it on too: tuple, `new`, `φ`, or mutable operand and result of call that takes it.
- Holder that names caller-visible place (argument, global) escapes value: later call that runs package code can release it.
- One `Base` or `Core` method releases only through function operand it calls, so count stays exact.
- Release of resource that path does not hold makes holds of its kind unknown; its throw gives them `possible`.
- Release that throws leaves its resource free: `unlock` throws only when task holds none (`ReentrantLock`). Lock that breaks this is its own bug.
- Place that summarizes several objects (array element) names none: each load is its own resource.
- F98 fact: statement may throw outside every `try` while method holds resource. Exact count gives definite; unknown gives `possible`.
- Helper that acquires (`hold!(q) = lock(q.lk)`) stays unseen: its caller gets no fact.
- `trylock` forks path: success side holds one more. Branch on result, or on its `!`, takes known side.
- At most 4 forks per block entry path; later `trylock` gives unknown count.

#### Compiler effects

- Compiler effects come free with unit inference.
- `unused-call` (F54) needs compiler proof: discarded call with `effect_free`, `nothrow` and `terminates`. Name trust never proves none for it.
- `@assume_effects` makes compiler trust a claim. Call to package method with claim takes no proof from its flags.
- Claim check reads code compiler infers. Generated method gives its generated code per instance.
- Claim deeper in callees stays unseen. `false-effects` reports a false claim in package that owns it.
- `false-effects` compares claims of package methods with their own write and read events.

#### Facts

- Per package method: `MethodEffects` with writes and reads by place, certainty and cause span; result aliases; holds; call facts; claims.
- Per call statement: callee, kinds of its writes, may throw, terminates, result used or discarded (F54, F86).
- Use counts before compaction: compaction turns each use of constant result into literal.
- Units of method merge by source statement: unit that may throw, writes or uses result decides.
- Per package method, F48: loop writes: span of loop start, span of write, writing function, confidence (`phase5.md`, row 7).
- Per package method, F50: self-alias calls: call span, writing function, confidence (`phase5.md`, row 7).
- Per package method, F51: stateful reuses: earlier and later event spans, which events escape, iterator text, confidence (`phase5.md`, row 7).
- Per unit, for `lifecycle` rules: allocation sites, read, write and start events per statement in control-flow order, must-alias pairs, escapes.
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
