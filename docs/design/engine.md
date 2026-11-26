# Effects engine

Whole-program effect summaries: points-to through Base and dependencies.

Engine code lives in `src/Effects/engine/`, module `Effects.Summaries`.
`effects` stage does not read engine verdicts yet: name trust gives its facts (`effects.md`, Name trust).

<div class="pipeline" role="img" aria-label="Effects engine steps from inference stage units to effects facts">
      <div class="layer"><div class="id">units</div><div class="what">Method and stand-in signature, from <code>inference</code> stage<small>same signatures and reached calls · no own roots</small></div></div>
      <div class="layer"><div class="id">IR</div><div class="what">SSA IR before inlining, from unit's typed code<small>passes until <code>CC: COMPACT_1</code> · no second inference</small></div></div>
      <div class="layer"><div class="id">call graph</div><div class="what">Instances that units reach, Base and dependencies included<small>strongly connected components · bottom-up</small></div></div>
      <div class="layer"><div class="id">summary</div><div class="what">Points-to with origins and provenance; writes, reads, result aliases<small>compiler effects skip empty summaries · library summaries cached</small></div></div>
      <div class="layer"><div class="id">verdict</div><div class="what">Worst over units of method; cut and opaque doubt go to coverage line<small>facts for rules and <code>lifecycle</code></small></div></div>
    </div>

### Units

- Effects reads units of `inference` stage: method and stand-in signature, plus signatures package calls reach. Effects adds no roots.
- Method gets verdict from its units only. Unannotated method no call reaches has none; `inference` stage counts it.
- Verdict of method: worst over its units.
- Incomplete method gets no definite none: signatures over limit, crash, inference without code, or type test (`inference` stage `incomplete`), or stand-in cut. Coverage reason names cause.
- Unit that always throws on its signature gives no verdict. Coverage reason: `always throws on stand-ins`.

### IR

- `inference` stage hands typed code of units it inferred this run to effects. Stored unit needs no typed code: its entry keeps effects record (see **Solve and cache**).
- Typed SSA IR before inlining: copy unit's unoptimized code; run compiler passes until `CC: COMPACT_1`. Package units need no second inference.
- Calls stay call statements, so allocations and consumers map to source through `inference` stage spans.
- Passes renumber statements. Before passes, line of each statement gets its source index; passes carry line to IR.
- Instance outside package: native inference, then same passes. Library cache skips both (see **Solve and cache**).

### Origins and points-to

- Origin: abstract object. Kinds: caller place (parameter or global path), allocation statement, `unknown`.
- Constant object in code counts as `unknown`: write to it is definite. Fresh objects of callee merge into one allocation at call statement.
- `unknown`: object open call can return that no operand names, global included. Write to it is `possible` global write.
- Current task is `unknown` without doubt: write to its fields is certain global write.
- One `unknown` origin stands for every outside object, so values stored into it take `code` doubt.
- Callee object outside its caller places maps to `unknown` and to each object caller stored into it. Each keeps doubt of its chain, at least `code`.
- Such caller object also maps to `deep` of its root: callee may reach below it.
- Task state access (`task_local`, `default_rng`, `scoped_read`) on `Elsewhere` stays on `unknown`: it names current task. Every other kind reaches those objects.
- Path: field name or element. Path follows declared field types.
- Path collapses to `deep` at step into concrete type it already passed (recursive type), at third abstract step in a row, or past 8 steps.
- Place says where access lands; certainty says whether it happens. `deep w` is coarse place: write below it still changes `w`.
- Field name comes from concrete type, array stand-in family or `Array` family. Other struct family (`Object{K, V} where …`) gives field position.
- Memory backing belongs to its owner: field of type `GenericMemory` or `GenericMemoryRef` adds no step. Write to `Vector` elements writes `Vector`.
- Callee or table access to owner may land on its memory alone or owner alone: memory behind it gets `possible` access (`pop!` of `Base.wrap(Array, m, n)`).
- Memory address (`Ptr`, `MemoryRef`) that callee returns names memory behind fresh owner: write through it writes that memory.
- `Ptr` value holds origins of object it points into, so foreign call through pointer writes that object. Data pointer of memory holds memory.
- Constant null pointer global (`C_NULL`) points into no object.
- Points-to: inclusion-based, field-sensitive, over SSA values and origin contents. Heap is flow-insensitive; SSA values keep flow.
- Unification is rejected: it merges unrelated objects at each unknown call.
- Write: statement that stores into origin content, or callee summary write mapped through call operands.
- Each origin in points-to set carries doubt: none, `code` or `blind`. Join keeps least doubt per origin.
- Open call on chain gives `code`.
- Merge of callee fresh objects is exact when they form one object: each fresh object but one backs another.
- `Array` and its `Memory` form one object: merged object backs itself.
- Exact merge also needs each slot to hold stores of one fresh object at most.
- Inexact merge gives `blind`: caller store into one merged object would show in the others.
- Collapsed path and load of non-constant slot add no doubt: object they reach lies below same root.
- Access below `deep w` takes kind of written object type at access, of callee access, or of `w` type.
- Exempt kind needs proof, as balanced lock use does. Raw write into `IO` memory below `deep w` is memory write: `# corset: allow` covers it.
- Access takes most doubt of effect and chain. None gives definite; `code` gives `possible`.
- `blind` gives blind access with cause `alias`: blind spot, counted on coverage line only.
- Summary per parameter and global: read and write of top object, each path, and `deep`. Each has certainty and cause span.
- Access says whether it covers every place below too. Open call covers whole object graph below each operand.
- Access below fresh object covers caller objects in its slots: open call on `(x,)` writes below `x`.
- Caller maps callee `deep` place: caller place below argument keeps access certainty. Caller object inside fresh argument gives `blind`: callee may leave it unchanged.
- Summary also gives result origins as parameter and global paths: result aliases. Fresh result keeps its fields: `view(A, 1:2)` result holds `A`.
- Summary gives stores callee makes between caller objects: `push!(v, x)` puts `x` into `v`, so caller write through `v[1]` writes `x`.
- Caller maps writes through result onto those paths, so write through result that aliases global is global write.
- Must-alias: two values whose points-to sets hold same single exact origin, and that origin is one object per call.
- Allocation site inside loop or recursion makes many objects: its origin gives may-alias only.

### Provenance

Doubt test (`findings.md`) needs to know where open type comes from.

Each unit argument has one provenance:

- Opaque: Corset chose its type and code did not. Its data gives blind spots only.
  - Argument without stand-in (declared narrower than `Any`); type variable with bound.
  - Stand-in with open part: `FunctionStandIn`, array stand-in with open element, struct stand-in whose parameter took its bound (`types.md`).
- Opt-out: source declares `::Any`; declared concrete type with `Any` parameter (`types.md`, Explicit `Any`). Its data gives no finding and no blind spot.
- Code: every other argument, untyped argument and type variable without bound included. Compiler sees same open type.
- Unit that calls reach keeps caller types. Only function stand-in and array stand-in with open part are opaque there.

Sources carry provenance through engine. No separate taint pass.

- `code` doubt holds sources: parameter bits, `OPAQUE` (`FunctionStandIn`) and `INHERENT` (doubt in code itself).
- Open dispatch (step 7) takes sources of each operand whose type is no dispatch element.
- Caller place gives its parameter. Global, or more than one fresh object, gives `INHERENT`. Chain to operand adds its own sources.
- Value without object source takes derived sources: type values and computed numbers hold no object. Objects decide when they give a source.
- Call result with open type derives sources of call operands with open type: `eltype(a)` and `w .* b` keep opaque source of open element.
- Argument with open type gives its parameter. Static parameter gives each parameter whose declared type holds it. Phi and pi nodes join sources of their values.
- Last fixpoint round records accesses: early round with sources still unknown adds no doubt in code.
- Callback record keeps targets only: its arguments give object sources alone.
- Two `code` doubts join sources, along chain and across chains. Callee summary maps parameter sources to sources of call arguments.
- Root unit resolves sources: code source gives `possible`. Else opaque source gives blind spot `open dispatch on opaque data`. Else no access.
- Unresolved call has doubt in code itself: unknown foreign call, builtin with splat, splat of other collection, splat that contract cannot place, `invoke` without constant method.
- `invoke` without constant method on contract function takes contract: contract covers every method (`Tuple{typeof(x)}` in Base logging).
- Provenance covers argument and every place below it. Argument with open part is opaque, so open type that code declares below it gives blind spot.
- Contract write on argument that admits consumed iterator (`iterate(x::Any)`) takes sources of that argument: its type decides write.
- Provenance judges doubt from open dispatch only. Writes code performs, and resolved, joined or contract writes, keep certainty on every origin: `f(x::Any) = setfield!(x, :n, 0)` writes `x`.

### Calls

Resolution of each call statement, first match wins:

1. Builtin or intrinsic: transfer function (`setfield!`, `memoryrefset!`, `setglobal!`, `swapfield!`, `modifyfield!`, `replacefield!`; `_apply_iterate` unpacked).
2. Foreign call: table of known C functions (`memmove` writes destination; runtime type queries read only). Unknown: `possible` write on pointer and object operands, doubt in code.
   - MPFR and GMP entries come from C headers: pointer to non-const is written, pointer to const is read (`mpfr_srcptr`, `const char *`). Generator: `gen/foreign/generate.jl`; output: `src/Effects/engine/foreign_gmp_mpfr.jl`.
   - Symbols: every MPFR and GMP function that Base and SpecialFunctions call, plus five numeric extras. The whole header holds about 800 functions; each one needs vetting for global state.
   - Hand entries (`calls.jl`) cover variadic functions and pointer results. `jl_get_current_task` returns `unknown` without doubt. Left open: functions that write C global state (`mpfr_set_emax`, `mpfr_set_emin`, `mpfr_clear_flags`, GMP allocator hooks).
   - PCRE2 entries cover functions that Base regex code calls, by PCRE2 API manual. Match writes match data and JIT stack of match context.
   - BLAS and LAPACK entries come from `\param` role comments of Reference-LAPACK source: `[out]` written, `[in]` read, `[in,out]` both. Generator: `gen/foreign/blas_lapack.jl`; output: `src/Effects/engine/foreign_blas_lapack.jl`.
   - Symbols: every BLAS and LAPACK routine that LinearAlgebra calls. `[in]` argument that routine modifies and restores (`A` of `?ormrz`) counts as written.
   - Hand entries cover CBLAS dot products and `?axpby`, which Reference-LAPACK lacks. `lbt_` configuration of libblastrampoline stays open.
   - BLAS entry applies only to call into libblastrampoline or OpenBLAS, by string or constant global. Same name in other library stays open.
   - No prefix rule: unknown `mpfr_` or `__gmp` name stays open, because wrong entry gives false definite write. Call with fewer arguments than entry names stays open too: same name, other library.
   - CI lacks the headers and LAPACK source. Generators do not run there; committed files are the source of truth. Tests compare them with hand classification.
3. Static call (one method matches, or `Core.invoke` with constant selector): callee summary. No method matches: call throws, so code after it is dead.
   Summary per variant: instance plus constant arguments callee uses as field name. `getproperty(x, :a)` keeps field `a`.
   Constant `Bool` argument that callee uses as branch condition also makes variant. Variant code drops blocks branch never reaches.
   Branch on `===` of two constants folds too: `getproperty(::Task, :rngState0)` variant drops `:backtrace` branch. Only variant constants fold; `===` adds no variant parameter.
   `HAMT.path(trie, key, h, false)` skips copy-on-write store, so `ScopedValue` read writes nothing. Julia inference resolves the same constant.
4. Static call on callable holding object below caller parameter: callee stores and result apply now. Accesses go into callback record for caller.
5. Run-time dispatch in package code with at most 3 matching methods: join their summaries. All agree: their certainty. Disagree: `possible`.
   Access that some members lack takes sources of open operands, as open dispatch does: operand types pick member.
   Blind access of one member and exact access of another disagree: join gives `possible`.
6. Base interface function with documented contract (`setindex!` writes collection; `length` reads only; `view` result lies within array). Breach in package method is finding.
7. Else open: `possible` write on operands; result may point into operands, one direction, and to `unknown`.
   Name states write whatever method runs. Base IO function (`print`, `write`, `read`) writes its `IO` stream operand: definite IO write.
   Stream is first operand; `write(to, from::IO)` also reads `from`. Value operand (`show(io, other::IO)`) takes open write only.
   Random draw (`rand`, `shuffle!`) writes its `AbstractRNG` first operand: definite RNG argument write.

- Splat of tuple or array with unknown length: dispatch on `Vararg` of element type. Callee parameters past fixed operands take any element.
- Splatted tuple slot has unknown position, so caller tuple collapses to `deep`. Splat of other collection stays open: its `iterate` runs.
- Instance specializes on call argument types. Callable type known to caller is concrete in callee too, so step 3 reaches its method.
- `@invokelatest f(x)` with constant `GlobalRef` resolves as call `f(x)`, keywords included (`Base.invokelatest_gr`).
- Constant binding has its value in analysis world. IR world range can start before binding exists: `@invokelatest` reads binding in latest world.
- Callback record keeps write path short. Tuple `foreach` wraps closure in `foldl` reducers: closure writes lie three steps below reducer.
- Caller maps record to its own objects. Callable still holding object below caller parameter passes record to next caller.
- Root unit has no caller: its verdict resolves records left in its summary.
- Record with fresh argument applies now: caller merges fresh objects of callee into one, so record would lose them.
- Join resolves records of its members. Member disagreement on access gives `possible`.
- Recursion repeats record on same targets: record applies once.
- Callable of abstract type stays open (step 7): solve reached no dispatch for caller type.
- Steps 5 and 6 assume methods loaded now. Write they find keeps certainty. "Writes nothing" from them is at most `possible`.
- Contract: `first` and generic `isempty` start iteration of argument (`isempty` docstring warns). Type with own `isempty` or `isdone` method uses its summary.
- Contract entry holds only behavior Base documents. Base type that writes where others read (`iterate` on `Iterators.Stateful`) gives `possible` write when operand type admits it.
- Query (comparison, size, predicate, arithmetic) reads arguments. Its result is new value.
- Alias query (`convert`, `getproperty`, `keys`, `max`, `conj`, `adjoint`) reads arguments. Its result may point beneath them.
- Element query (`getindex`) result is element of collection or lies beneath it, never in indices.
- Iteration (`iterate`, `first`, `only`, `isempty`, `in`) reads like element query. `Iterators.Stateful`, `Channel` and `EachLine` get `possible` write.
- Write contract (`setindex!`, `push!`, `append!`, `resize!`, `pop!`, `copyto!`, `merge!`) writes first argument and stores or copies elements into it.
- Collection whose `eltype` points to no object (`Vector{UInt8}`) takes no stored object: Julia converts value at store. Foreign call table keeps every store: C pointers are untyped.
- Function with callable-first form (`get`, `get!`, `merge!`): contract holds only when first argument cannot be callable. Else call stays open.
- Keyword call of contract function: keyword tuple takes rest role. Contract needs rest role that only reads.
- Keyword callable (`by`) runs as callback, so keyword call with callable value stays open.
- Logger interface (`AbstractLogger`): `shouldlog`, `min_enabled_level` and `catch_exceptions` are queries.
- `handle_message` reads message and keywords. Logger takes IO write: message goes to its sink.
- Contract keeps no record of logged values: `Test.TestLogger` stores them, Base documents no store.
- Query result that may alias every argument tripled JSON `effects` time and changed no verdict.
- Open call (step 7) whose open operands come from opaque and opt-out arguments only: no finding (Provenance). Opaque argument counts on coverage line: `open dispatch on opaque data`.
- Other open call: doubt in code, `possible` finding.
- Limit 3 is compiler `max_methods`, never below. Limit 8 reached 20 times more instances on Distances.
- Library code joins nothing: its run-time dispatch stays open (step 7). Joins there raised `possible` share and cost most time.

### Compiler effects

- Compiler effects come free with unit inference and native cache.
- Instance with `effect_free`, `inaccessiblememonly`, `notaskstate` and result type that holds no reference has empty summary. Engine skips own analysis and callees there.
- `notaskstate` keeps `ScopedValue` reads: Base claims `effect_free` and `inaccessiblememonly` for them.
- `effect_free` proves one direction. True: instance writes nothing caller sees, so its own verdict is none.
- False proves no write: dynamic call or IO also clears it. Own analysis decides then, per argument and global.
- Callee summary needs more than `effect_free`: result aliases. `view` writes nothing, but caller writes `A` through `view(A, 1:2)`.
- `@assume_effects` makes compiler trust claim. Shortcut holds only when no instance it reaches carries claim outside Base or stand-in cut.
- Claim: `@assume_effects` on method or on block in it. Generated method and method without source count as claim.
- Native inference edges tell reach. Callee without cached code counts as claim. Corset, Moshi and Compiler carry claims, so each run checks reach of claims.
- Compaction deletes unused call when compiler effects allow. Call that reaches claim or cut stays, and so does statement under block claim of claiming method.
- Unit keeps every call: call facts need discarded calls (Facts). Unit with shortcut keeps code too; its summary stays empty.
- Own analysis runs on every method with claim outside Base. `false-effects` compares claims of package methods.

### Stand-in cuts

- Cut: call or store statement live at declared signature and dead at stand-in signature. Engine never sees it, so unit summary carries `cut`.
- Causes: call that fails on stand-in only, whose callee engine never sees; type test that stand-in decides (`x isa BigFloat && (STATE[] += 1)`).
- `inference` stage finds cuts: units with dead call or store statements first, then declared-signature inference of those units only.
- Failure check of units gives failing calls: model-type inference decides them. Throw helpers fail on every signature, so they are never cut.
- Package call that fails on stand-in only gets no failure-check spot, but stays cut: stand-in can dispatch to other method.
- Package units and library instances count both causes, with model-type check for library instances.
- Base, Core and stand-in methods count failing calls only: Base keeps documented contracts, so its type branches keep same effects (`findings.md`, Confidence and blind spots).
- Generated code differs per signature. Its statements match no statement of other signature, so generated method clears no cut.
- Callers inherit `cut`. Method with `cut` is incomplete. Verdict none with `cut` goes to coverage line: `stand-in cuts path`.
- Blind spot points at first cut statement, else at first call whose callee carries `cut`.
- Definite and `possible` writes keep certainty with `cut`.
- Compiler effects of stand-in instance skip code past cut. Shortcut and compaction treat instance with cut like claim (Compiler effects).
- Library cut check runs only on instance that holds stand-in: method outside Base, or call that can fail (not `nothrow`, or method with `try`). Caught failure keeps `nothrow`.

### Effect kinds

Summary keeps every effect with its kind. Rules apply exemptions; engine filters nothing.

- Kinds: memory write, IO, default RNG, RNG argument, task-local state, `ScopedValue` read, lock and other synchronization, lazy init, audited internal state, iteration start.
- `bang-convention` exempts IO, RNG, lazy init and audited internal state. `unused-call` counts every kind. `hidden-input` reads default RNG, task-local state, `ScopedValue` and mutable globals.
- Access key holds place, below flag and kind. Memory write and IO write on one place keep own doubt each.
- Kind comes from types along place path, root first: first `IO` gives IO, `AbstractRNG` gives RNG argument.
- Contract write can set own kind: `handle_message` writes logger as IO.
- Lock, `Condition` and `Semaphore` on path give synchronization. Path without such type gives memory write.
- Path types: instance parameter type, constant global value type or global binding type, then field type or element type per step. Abstract type without field ends walk.
- Instance that maps callee access onto own place classifies again: memory write takes special kind when own path crosses special type.
- Write to RNG fields of `Task` (`rngState0` to `rngState4`): default RNG. Other write to `Task`, `task_local_storage` included: task-local state.
- Caller chooses default RNG for unit whose argument holds `TaskLocalRNG` where method declares type that takes any RNG.
  - Unit verdict moves default RNG accesses to that argument; kind stays default RNG. Summary keeps default RNG for callers.
  - `false-effects` still sees `Task` state there. `hidden-input` counts default RNG on `Elsewhere` only.
  - Such unit comes from call that also passes stand-in: `f(default_rng(), d)` with stand-in `d`; `f(default_rng())` gives none.
  - Condition: each call that reaches default RNG gets argument, or tuple or closure built from it.
  - `TaskLocalRNG` is singleton: inference folds closure over argument to constant. Constant that holds `TaskLocalRNG` counts as argument.
  - Closure over explicit `default_rng()` folds to same constant. Declared signature unit keeps its default RNG access.
  - Method that declares `TaskLocalRNG` chose default RNG itself: its accesses stay default RNG on `Elsewhere`.
  - Bare `rand()` beside `rand(rng)`, or builtin access to `Task`, keeps default RNG.
  - Callee that gets argument and also draws default RNG: package callee verdict keeps it, so `hidden-input` reports callee.
  - Library callee that gets argument and draws default RNG: caller verdict misses it. Fix needs default RNG provenance in summaries.
- `ScopedValue` read: read of `ScopedValue` object or of current task scope.
- Lock write: lock or semaphore of argument or global changes hold count by normal exit (Release balance). Balanced use writes nothing.
- Lazy init and audited internal state come from audited table of Base types and methods only:
  - Table keys holder type and field, global binding, or method. Listed entry sets kind before path types.
  - Audited field sets kind of every place below it: JIT compile writes code below `Regex` field.
  - Audited global sets kind only in methods of its own package. Caller that writes `Dict` from `parsed_toml` writes memory.
  - `Regex` compile cache, `LazyString`; Base logging and PCRE contexts.
  - IO bookkeeping: temporary path cleanup (`mktempdir`), libuv handles kept alive (`preserve_handle`).
  - Lazy caches: parsed TOML, loading cache, docstring modules, stack trace module colors.
  - Synchronization: Base task queues (`Workqueues`, `Partr.heaps`) that `wait`, `yield` and `schedule` change.
  - Logging `JULIA_DEBUG` cache (`env_override_minlevel`) and frame lookup of deprecation (`_depwarn`): unknown objects they write.
  - Repair method `unsafe_convert(Ref{BigFloat}, ::BigFloatData)`: rewrites stale MPFR limb pointer before each call.
- Package `setfieldonce!` and package caches follow memo-cache rule above: cheap proof or opt-out.
- Write to other module's global outside audited table counts as global write; requirement propagates.
- Writes to fresh local objects inside error paths (message building) are local writes.
- Argument or global write before throw stays in summary: caller that catches sees it, open calls included (`foreign_mutate!(x); error()`).
- Message call: call whose result feeds only thrown value, directly or through other message statements. It adds definite writes only.
- Thrown value: argument of `throw` or of throw-helper call (`error`). Other call that never returns fails on stand-in: stand-in cuts handle it.
- Use cycle never counts: `string` call that builds message in loop keeps its writes.
- Message call resolves callback records at call: record would carry its writes to caller.
- Throw-only exemption (F86) needs no write on any path.

### Release balance

Summary keeps hold count per resource place at normal exit and at throw exit. Count is exact (acquires less releases), unknown, or blind.

- Resources: lock, `Semaphore` slot, file that `open` returns. Resource place: one target of operand, exact caller place or fresh object.
- Count key: resource place and resource kind. Fresh `IOStream` holds file and own lock: they count apart.
- Merged fresh objects of callee count together: `open` result is one of them.
- Operand with other targets: blind spot `release pattern`.
- Primitive table: `lock`, `unlock`, `trylock` on lock; `acquire`, `release` on `Semaphore`; `open` with `IOStream` result; `close` on `IOStream`.
- Table also: `wait(::Condition)` releases lock and takes it again.
- Engine never reads lock, semaphore or `wait` bodies. It reads `open` and `close` bodies for their IO.
- Base libuv lock (`iolock_begin`) holds no Julia object: engine skips it.
- `lock(f, l)`, `open(f, path)` and `@lock l expr` need no entry: each releases in `finally`, which dataflow balances.
- `trylock` gives blind spot `release pattern`. Count that follows its result comes later.
- Dataflow over CFG blocks. Statement that may throw (compiler `nothrow` off) inside `try` has edge to its catch block.
- Block keeps at most 4 paths: counts and branch conditions taken. Fifth path joins all paths into one.
- Branch on condition that path took before takes same side: `l && lock(x) … l && unlock(x)` balances (Base `@_lock_ios`).
- Condition is forgotten when loop runs its statement again.
- Primitive that throws: acquire takes nothing, release still counts. `unlock` throws only when lock is not held.
- Join of different counts gives unknown; count that grows round a loop gives unknown.
- Throw exit: statement that may throw outside every `try`. Its count joins into throw-exit count.
- Call applies callee counts on caller places like writes: through join and callback record. Callee throw-exit count joins at call statement.
- Normal-exit lock or semaphore count not 0 on argument or global: lock write. Exact count gives definite; unknown from join gives `possible`.
- F98 (`unguarded-release`) fact: statement throws outside every `try` while method holds resource. Release is skipped.
- Hold comes from own acquire or callee normal exit. Callee throw-exit count alone gives none: finding goes to method that acquires.

### Solve and cache

- Call graph over variants; strongly connected components from iterative Tarjan; solve bottom-up.
- Inside component: worklist. Member reads summaries of callees and of callback record variants it resolves. Member reruns when read summary changes.
- Inside instance: rounds over IR until targets settle. These rounds apply callee stores only. One settled round then applies callee accesses.
- Join of methods (Calls, step 5) is not monotone, so summaries in cycle can oscillate.
- After 8 reruns, member summary widens: union with previous summary. Access that still changes becomes blind (`unsettled call cycle`).
- Widened summaries only grow through finite values, so fixpoint ends.
- Flow work: targets that loads trace and joins read, over every round of one variant.
- Flow past work limit stops. Variant gets open summary: blind access on each parameter, blind spot `effects budget`.
- Work counts origins each trace walks. Load past limit returns nothing, so one call statement stops too.
- Root past limit keeps no call facts: its rounds stopped early.
- Limit: 10 million, 10 times largest flow on corpus (Distributions, 0.95 million).
- Callee signature can grow along call chain without end: `_any(f ∘ transpose, parent(A), :)` adds `ComposedFunction` layer per step.
- Engine limits callee like native inference (`abstract_call_method`): method that recurs on call chain gets `limit_type_size` signature.
- Call chain: caller that first reached each instance. Join limits hard, against method signature.
- Library instance: method outside package, and signature names no package type.
- Library summary: variant of library instance. Disk cache keeps it; cache hit skips native inference and passes.
- Cache also keeps variant parameters and stand-in cut of library instances.
- Partition: Julia version, cache flags and Corset content. One library file per partition serves every checked path and environment.
- Entry key: kind, closure key of instance, and constants of variant. Module constant adds its owner text.
- Closure key: digest over strongly connected components of native edge graph, callees first. Walk order cannot change it.
- Node: cached code instance, else instance that run inferred. Lookup before native inference needs cached code; instance without it misses.
- Node text: instance key, text of each edge record, and owner digest of each root module that instance or records name.
- Instance key: canonical text of method signature and of specialization. Type text: module path, name, parameters; variables by binding depth.
- Edge records of Julia 1.13: lookup with match count, single match, binding, call type with method table, call type with `invoke` target.
- Lookup count is negative when matches do not cover call. Too many matches give no record, so push past method limit changes key.
- Package method that changes dispatch of library call removes cached code of caller. New code gives other edge records.
- Owner text: package content and texts of its loaded dependencies. Extension: texts of parent and triggers. Base and Core: none.
- Corset gives texts of its dependencies only: partition holds its content.
- Package content: path in depot `packages` or standard library, since depot slug derives from tree hash. Else digest of project file, `src`, `ext` and `deps`.
- Package content adds preferences of package. Edit of unrelated package keeps key.
- No key: package code, `Main` code, root without project file, unknown edge form, or edge target without node.
- Solve of shared variant stays inside native edges of its node. Union split, folded call and callee limit can leave them.
- Core methods of `!==` and `>:` count as inside: inference reads them as `===` and `<:`. Closure key holds their other methods.
- Variant whose solve reaches package code or unshared variant stays out. Summary with callback record stays out: caller needs record variants too.
- Throw helper verdict reads every method of callee. Entry keeps each verdict its closure read; hit checks each again.
- Stand-in cut that inferred model types reads methods outside native edges. Store gives no key to closure that holds its instance.
- Library file lists instance key of each entry. Lookup walks closure only for listed instance.
- Write reads file again, merges new entries, and stamps hits. Entries go newest first within 128 MiB.
- Write goes to staging file, then rename. Concurrent writer can lose entries; file stays whole. Directory keeps newest 4 library files.
- Run that skipped crashed instance stores nothing: its blind spot holds for that run only.
- Package summary: method store entry keeps effects record of unit beside `Inferred`, with same invalidation.
- Record: accesses with spans, holds, call facts, blind spots and cuts. Call fact names callee methods by signature, since deserialized `Method` is new object.
- Effects run infers again each unit whose entry has no record. Inference run keeps records of stored entries.
- Stored unit that fresh unit calls gets unit body from native inference and no first caller, as in cold run.
- Stored units start no walk, so first caller of library instance can differ from cold run. Only recursion limit reads call chain.
- Budget: with warm library cache, effects stage takes at most `inference` stage time.
- Corpus cost: history, "Engine cost" and "Engine freeze".

### Facts

- Per package method: writes and reads by place with certainty and cause span; blind writes and reads with blind spot; result aliases.
- Iteration starts by place: `iterate` without state, directly or through callee. Summary joins and widens them like reads.
- Start is read of kind `iteration`. Base contract of `first`, `only`, generic `isempty` and destructuring starts too.
- Fact of incomplete method has `complete` false: it gets no definite none.
- Per unit, for `lifecycle` and statement rules (F48, F50, F51): allocation sites, read, write and iteration-start events per statement in control-flow order, must-alias pairs, escapes. One producer per fact.
- Element event carries index operand: constant or SSA value. `lifecycle` decides which elements writes cover (F33, F34).
- Per call statement: callee, kinds of its writes at any certainty, may throw, terminates, result used or discarded (F54, F86).
- Callee holds that call leaves count as writes: lock gives synchronization, file gives IO.
- Use counts before compaction: compaction turns each use of constant result into literal (`b == UInt8('\t')`).
- Units of method merge by source statement: unit that may throw, writes or uses result decides.
- `unused-call` needs no effect of any kind, no throw and termination: discarded `parse(Int, text)` validates input.
- Join of two allocations at branch (`y = flag ? a : b`) makes fact `possible`.
- Callee content reads come from summaries: `sum` reads, `fill!` does not.
- `possible` effect findings stay off until call resolution passes quality gate.

### Tests

- Fixture per transfer function, resolution step, origin kind and benign write.
- Soundness property (Supposition.jl): run fixture function on generated inputs; compare deep copies before and after. Observed write needs definite or `possible` in summary.
- UI tests per rule; mutation testing on engine; corpus go/no-go (`plan.md`).
