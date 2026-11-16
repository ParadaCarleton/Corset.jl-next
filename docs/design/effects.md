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
- Write facts come from Corset's own summary per method instance (S5): points-to classes inside method, callee summaries at calls. Compiler `EscapeAnalysis` is unsuitable: no return-alias or field-store summary.
- IR: typed SSA IR before inlining, on same inference as `inference` stage. Calls stay call statements, so allocations and their consumers map to source through phase 4 source map. Engine PR measures instance count, unknown foreign calls, peak memory, and cold and warm time against S5 optimized IR.
- Summary per parameter: write and read of top object and of reachable objects, each definite, possible or none. Lifecycle reads need content reads (`similar` then `sum`).
- Callees are summarized through dependency code, Base included. Base summaries are cached once per Julia version.
- Call resolution, first match wins:
  1. Static call: callee summary.
  2. Callee is parameter, also through `_apply_iterate`: summary records call of parameter with its operands. Combinator itself writes nothing, so `map` and `foreach` need no `!`. Caller that knows callee substitutes its summary, captured aliases included: `run(sink, xs) = foreach(x -> push!(sink, x), xs)` writes `sink`. Same for `Base.Fix1(push!, sink)` and callable struct read from field.
  3. Run-time dispatch with at most 4 candidates at declared signatures: join summaries. All agree: definite. Disagree: `possible`.
  4. Base interface function with documented contract: contract summary from table. Each entry lists reads, writes and result alias per argument: `setindex!` writes collection; `getindex`, `iterate`, `length`, arithmetic read only; `view` result lies within array; `convert` result can be argument. Package method on contract function is checked against contract; breach in target package is finding.
  5. Generic function of package or dependency: join summaries of every loaded method that matches. Join over more than 64 methods is unknown.
  6. Else unknown: `possible` write on each operand. Result may point into operands; operands stay apart. Coverage line counts unknown calls by reason.
- Steps 4 and 5 assume: later method can break contract (`getindex` on `DefaultDict` inserts) or extend function. Write they find keeps its certainty. "Writes nothing" from them is at most `possible`, so it never backs definite `unused-call` or spurious `!`.
- `!` in callee name is never write evidence. On S5 corpus, trusting names gave 7 false definite findings in Distances: `colwise!` writes second argument.
- `possible` effect findings stay off until dispatch resolution passes quality gate.
- `lifecycle` reads effects facts per allocation site: allocation identity, must-alias facts, read and write events per statement in control-flow order, escapes. Callee content reads come from summaries (`sum` reads, `fill!` does not). Join of two allocations at branch (`y = flag ? a : b`) makes fact `possible`. One producer per fact; def-use on syntax would redo aliasing (`y = x; y[1] = 0`).
- Not writes caller sees: lazy-init caches (`Regex`, `LazyString`, `setfieldonce!`), task-local state, locks, writes to fresh local objects inside error paths (message building). Argument or global write before throw stays in summary: caller that catches sees it. Unknown calls on throwing paths add no `possible` writes; definite writes there stay. Throw-only exemption (F86) needs no write on any path. Globals of other modules (Base logging, PCRE contexts) are kept apart and never reported.
- Effect summary records whether method result aliases global state. Write through such result counts as global write, so caller needs `!`.
- Requirement propagates: caller of `!` function on global state needs `!` too.
- Full ownership (borrow) checking is deferred. Revisit for concurrency rules.

### `!` scope

Argument and global writes. IO and RNG exempt. Memo caches exempt with cheap proof only.

### Borrow checking

Defer. Revisit for concurrency rules.
