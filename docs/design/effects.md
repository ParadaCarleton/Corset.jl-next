# Effects

`!` convention and effect summary.

`!` marks every function that can change state outside itself, IO excepted. When behavior is inconsistent, `!` names functions where bug can be.

<div class="flow" role="img" aria-label="Decision steps for whether a function needs a bang">
      <div class="q"><div class="ask">Does method write memory caller can see?<small>Corset write summary per method</small></div><div class="out">no → no <code>!</code></div></div>
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
- Callee name is never write evidence: `!` does not tell which argument changes.
- Requirement propagates: caller of `!` function on global state needs `!` too.

### Effects engine

Engine code lives in `src/Effects/`.

<div class="pipeline" role="img" aria-label="Effects engine steps from inference stage units to effects facts">
      <div class="layer"><div class="id">units</div><div class="what">Method and stand-in signature, from <code>inference</code> stage<small>same signatures and reached calls · no own roots</small></div></div>
      <div class="layer"><div class="id">IR</div><div class="what">SSA IR before inlining, from unit's typed code<small>passes until <code>CC: COMPACT_1</code> · no second inference</small></div></div>
      <div class="layer"><div class="id">call graph</div><div class="what">Instances that units reach, Base and dependencies included<small>strongly connected components · bottom-up</small></div></div>
      <div class="layer"><div class="id">summary</div><div class="what">Points-to with origins and provenance; writes, reads, result aliases<small>compiler effects skip empty summaries · library summaries cached</small></div></div>
      <div class="layer"><div class="id">verdict</div><div class="what">Worst over units of method; cut and opaque doubt go to coverage line<small>facts for rules and <code>lifecycle</code></small></div></div>
    </div>

#### Units

- Effects reads units of `inference` stage: method and stand-in signature, plus signatures package calls reach. Effects adds no roots.
- Method gets verdict from its units only. Unannotated method no call reaches has none; `inference` stage counts it.
- Verdict of method: worst over its units.
- Incomplete method gets no definite none: signatures over limit, crash, inference without code, or type test (`inference` stage `incomplete`). Coverage reason names cause.
- Unit that always throws on its signature gives no verdict. Coverage reason: `always throws on stand-ins`.

#### IR

- `inference` stage hands typed code of units it inferred this run to effects. Method store keeps facts only; stored unit keeps its stored summary.
- Typed SSA IR before inlining: copy unit's unoptimized code; run compiler passes until `CC: COMPACT_1`. Package units need no second inference.
- Calls stay call statements, so allocations and consumers map to source through `inference` stage spans.
- Instance outside package: native inference, then same passes. Library cache skips both (see **Solve and cache**).

#### Origins and points-to

- Origin: abstract object or value. Kinds: parameter path, global path, allocation site, call result site, constant, `unknown`.
- `unknown`: object open call can return that no operand names, global included. Write to it is `possible` global write.
- Path: field name or element, at most 2 steps. Longer path collapses to `deep`.
- Points-to: inclusion-based, field-sensitive, over SSA values and origin contents. Heap is flow-insensitive; SSA values keep flow.
- Unification is rejected: it merges unrelated objects at each unknown call.
- Write: statement that stores into origin content, or callee summary write mapped through call operands.
- Definite write: reachable statement writes origin, and no collapsed path or merged call result lies on chain to it.
- Collapsed path or merged call result gives `possible` with cause `alias`: blind spot, counted on coverage line.
- Summary per parameter and global: read and write of top object, each path of depth 1 and 2, and `deep`. Each has certainty and cause span.
- Summary also gives result origins as parameter and global paths: result aliases.
- Caller maps writes through result onto those paths, so write through result that aliases global is global write.
- Must-alias: two values whose points-to sets hold same single exact origin, and that origin is one object per call.
- Allocation site inside loop or recursion makes many objects: its origin gives may-alias only.

#### Provenance

Doubt test (`findings.md`) needs to know where open type comes from.

Each origin has one provenance:

- Opaque: Corset chose its type and code did not. Its data gives blind spots only.
  - Argument without stand-in (declared narrower than `Any`); element of stand-in array with element `Any`.
  - Struct stand-in field whose parameter took its bound; result of `FunctionStandIn` call (`types.md`).
- Opt-out: explicit `::Any` argument, field or element type declared `Any` (`types.md`, Explicit `Any`). Its data gives no finding and no blind spot.
- Code: every other origin, untyped argument and untyped field included. Compiler sees same open type.
- Provenance flows with origins through points-to and callee result aliases. No separate taint pass.
- Provenance judges doubt from open dispatch only (step 7). Writes code performs, and resolved, joined or contract writes, keep certainty on every origin: `f(x::Any) = setfield!(x, :n, 0)` writes `x`.

#### Calls

Resolution of each call statement, first match wins:

1. Builtin or intrinsic: transfer function (`setfield!`, `memoryrefset!`, `setglobal!`, `swapfield!`, `modifyfield!`, `replacefield!`; `_apply_iterate` unpacked).
2. Foreign call: table of known C functions (`memmove` writes destination; runtime type queries read only). Unknown: `possible` write on pointer and object operands, doubt in code.
3. Static call (`:invoke`, or one method matches): callee summary.
4. Callee is parameter, type from static parameter, or field callable: summary records call with operands. Caller that knows callee substitutes its summary, captured aliases included.
5. Run-time dispatch with at most 8 matching methods: join their summaries. All agree: their certainty. Disagree: `possible`.
6. Base interface function with documented contract (`setindex!` writes collection; `length` reads only; `view` result lies within array). Breach in package method is finding.
7. Else open: `possible` write on operands; result may point into operands, one direction, and to `unknown`.

- Steps 5 and 6 assume methods loaded now. Write they find keeps certainty. "Writes nothing" from them is at most `possible`.
- Contract entry holds only behavior Base documents. Base type that writes where others read (`iterate` on `Iterators.Stateful`) gives `possible` write when operand type admits it.
- Open call (step 7) whose open operands point to opaque and opt-out origins only: no finding. Opaque origin counts on coverage line: `open dispatch on opaque data`.
- Other open call: doubt in code, `possible` finding.
- Limit 8 is first guess; engine PR measures it. Never below compiler `max_methods`.

#### Compiler effects

- Compiler effects come free with unit inference and native cache.
- Instance with `effect_free`, `inaccessiblememonly` and result type that holds no reference has empty summary. Engine skips own analysis there.
- `effect_free` proves one direction. True: instance writes nothing caller sees, so its own verdict is none.
- False proves no write: dynamic call or IO also clears it. Own analysis decides then, per argument and global.
- Callee summary needs more than `effect_free`: result aliases. `view` writes nothing, but caller writes `A` through `view(A, 1:2)`.
- `@assume_effects` makes compiler trust claim. Shortcut holds only when no method instance reaches outside Base carries effects override; call graph tells.
- Own analysis runs on every method with claim outside Base. `false-effects` compares claims of package methods.

#### Stand-in cuts

- Cut: call or store statement live at declared signature and dead at stand-in signature. Engine never sees it, so unit summary carries `cut`.
- Causes: call that fails on stand-in only; type test that stand-in decides (`x isa BigFloat && (STATE[] += 1)`).
- `inference` stage finds cuts: units with dead call or store statements first, then declared-signature inference of those units only.
- Package units count both causes. Library instances count failing calls only: Base type branches keep same effects (`findings.md`, Base contracts).
- Callers inherit `cut`. Verdict none with `cut` goes to coverage line: `stand-in cuts path`.
- Definite and `possible` writes keep certainty with `cut`.

#### Effect kinds

Summary keeps every effect with its kind. Rules apply exemptions; engine filters nothing.

- Kinds: memory write, IO, default RNG, RNG argument, task-local state, `ScopedValue` read, lock and other synchronization, lazy init, audited internal state.
- `bang-convention` exempts IO, RNG, lazy init and audited internal state. `unused-call` counts every kind. `hidden-input` reads default RNG, task-local state, `ScopedValue` and mutable globals.
- Lazy init and audited internal state come from audited table of Base types and methods only:
  - `Regex` compile cache, `LazyString`; Base logging and PCRE contexts.
  - Repair method `unsafe_convert(Ref{BigFloat}, ::BigFloatData)`: rewrites stale MPFR limb pointer before each call.
- Package `setfieldonce!` and package caches follow memo-cache rule above: cheap proof or opt-out.
- Write to other module's global outside audited table counts as global write; requirement propagates.
- Writes to fresh local objects inside error paths (message building) are local writes.
- Argument or global write before throw stays in summary: caller that catches sees it, open calls included (`foreign_mutate!(x); error()`).
- Calls whose results feed only thrown value (message building) add no `possible` writes.
- Throw-only exemption (F86) needs no write on any path.

#### Solve and cache

- Call graph over instances; strongly connected components from Graphs.jl; solve bottom-up.
- Inside component: worklist. Member reruns only when summary it read changed. Lattice is finite, so fixpoint ends.
- Library summary: instance whose signature names no package type and whose edges reach no package method. Targets share its disk cache.
- Key: Julia version, Corset version, loaded extensions, and content digest of each loaded package: Manifest tree hash, or source digest for path and developed packages.
- Package summary: method store entry beside `Inferred`, same invalidation.
- Budget: with warm library cache, effects stage takes at most `inference` stage time.
- Solver cost and accuracy are unmeasured. Engine PR measures both on corpus before rule PRs.

#### Facts

- Per package method: summary verdict per parameter and global, cause spans, result aliases, blind spots by reason.
- Per unit, for `lifecycle` and statement rules (F48, F50, F51): allocation sites, read and write events per statement in control-flow order, must-alias pairs, escapes. One producer per fact.
- Element event carries index operand: constant or SSA value. `lifecycle` decides which elements writes cover (F33, F34).
- Per call statement: callee, effect kinds, may throw, result used or discarded (F54, F86).
- `unused-call` needs no effect of any kind, no throw and termination: discarded `parse(Int, text)` validates input.
- Join of two allocations at branch (`y = flag ? a : b`) makes fact `possible`.
- Callee content reads come from summaries: `sum` reads, `fill!` does not.
- `possible` effect findings stay off until call resolution passes quality gate.

#### Tests

- Fixture per transfer function, resolution step, origin kind and benign write.
- Soundness property (Supposition.jl): run fixture function on generated inputs; compare deep copies before and after. Observed write needs definite or `possible` in summary.
- UI tests per rule; mutation testing on engine; corpus go/no-go (`plan.md`).

### `!` scope

Argument and global writes. IO and RNG exempt. Memo caches exempt with cheap proof only.

### Borrow checking

Defer. Revisit for concurrency rules.
