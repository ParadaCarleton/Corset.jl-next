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
- Write facts come from Corset's own summary per method (S5): points-to graph over optimized IR inside method, callee summaries at calls. Compiler `EscapeAnalysis` is unsuitable: no return-alias or field-store summary.
- Callees are summarized through dependency code, Base included. Base summaries are cached once per Julia version.
- Dynamic call: join summaries of up to 4 candidates at declared signatures; definite only when all agree. Else unknown callee: `possible`, reason recorded for coverage line.
- `possible` effect findings stay off until dispatch resolution passes quality gate. S5: every `possible` verdict came from unknown callee or foreign call.
- Not writes caller sees: lazy-init caches (`Regex`, `LazyString`, `setfieldonce!`), task-local state, locks, writes inside error paths. Globals of other modules (Base logging, PCRE contexts) are kept apart and never reported.
- Effect summary records whether method result aliases global state. Write through such result counts as global write, so caller needs `!`.
- Requirement propagates: caller of `!` function on global state needs `!` too.
- Full ownership (borrow) checking is deferred. Revisit for concurrency rules.

### `!` scope

Argument and global writes. IO and RNG exempt. Memo caches exempt with cheap proof only.

### Borrow checking

Defer. Revisit for concurrency rules.
