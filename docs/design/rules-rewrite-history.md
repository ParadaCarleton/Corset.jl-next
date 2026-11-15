# Corset rewrite: old rule names

Record of rules on main, ideas from open work, and early decisions that use old names.
Design page `rules-rewrite.html` replaces them with footguns and rules. Rewrite called rules "checks" until rename below.

## Rules on main, kept or changed

External tools `jet` and `fatou` stay; not reviewed. Names follow `main`, which renamed `unstable-variable`, `unstable-return` and anonymous-function rules. PRs based on older `main` still use old names.

| Rule | Group | Family | Finds | Status · rewrite note |
|---|---|---|---|---|
| no-op | correctness | E | Function returns `nothing` and has no side effect. | new · replaces bang Effect-free per `infer_effects` and returns `nothing`. |
| unmarked-mutation | correctness | E | Function without `!` writes argument or global state. | changed Global writes added. See ! convention . |
| hidden-input | correctness | E | Read of mutable or non-constant global, or `ScopedValue`. | kept |
| captured-mutation | correctness | E | Anonymous function writes state it captured. | split from impure-anon-fun Today rule flags captures by type only, with no mutation analysis (`src/rules/general.jl:564`). |
| where-return | correctness | A | `f(x::T)::T where {T} = x`: `where` binds result type. | kept · fixer Parse verified on Julia 1.12. |
| broad-catch | correctness | A | `catch` that handles every error and rethrows none. | kept |
| nothing-return | correctness | A | Declared `Union{Nothing, …}` result. | moved from pedantic Fail-loud API. |
| repeated-statement | correctness | A·E | Same statement twice in one block. | changed Exempt calls with effects (`pop!`, `readline`). |
| non-atomic-write | correctness | A | Loop writes several files without staging. | kept |
| nan-initializer | correctness | B | `zeros`/`ones`/`fill` array later written; unwritten element looks like data. | replaced in #128 See `unwritten-undef` in open work . |
| unstable-variable | performance | D | Local variable with vague inferred type. | changed Union policy by owning module; same as unstable-return and abstract-field. See decisions . |
| unstable-return | performance | D | Result type callers cannot compile against. | changed Member-count limit gives way to union policy by owning module. See decisions . |
| runtime-dispatch | performance | D | Call resolved at run time. | kept |
| recursion-limit | performance | D | Recursion with argument types that nest deeper each call. | kept |
| float-widening | performance | D | Literal or constant widens input type (`Float32` → `Float64`, `Int32` → `Int64`). | kept Absorbs removed `float64` rule. #113 groups it under `type-disruption`. |
| abstract-field | performance | C | Struct field with vague type. | kept |
| unstable-anon-fun | performance | F | Capture with vague inferred type. | kept |
| boxed-capture | performance | F | `Core.Box`: captured variable rebound. | split from impure-anon-fun |
| specialization-blowup | performance | F | Method with many specializations that differ only in `Function` or `Type` parameter. | open · replaces overspecialized-anon-fun Closure and plain argument both specialize per function (measured: 4 and 4). Suggest `@nospecialize`. |
| quadratic-scan | performance | A | Loop searches same collection once per element. | kept |
| quadratic-vcat | performance | A | Fold joins pieces one at a time. | kept · fixer |
| constant-array | performance | B | Never-written array of zeros or ones; FillArrays avoids allocation. | kept · fixer Proposal: skip small constant sizes. |
| concrete-arg | composability | B | `::Vector`/`::Dict` argument the method never resizes. | replaced in #115 See `concrete-annotation` in open work . |
| non-public-access | composability | C | Use of another module's internal name. | kept Consider wrapping ExplicitImports.jl. |
| return-type | composability | A | Call of `Core.Compiler.return_type`. | kept |
| concrete-return | composability | A | Result annotation names concrete type. | open · purpose unclear Silent conversion by result annotation stays unchecked. `concrete-annotation` (#115) also covers results. |
| annotation | readability | A | Argument or result without type. | kept `::Any` is explicit opt-out. Abstract types (`::Real`) intended. |
| one-letter | readability | A | One-letter variable name. | changed · partly open Allow `i` for indices. `j`, `k`, `T` open. |
| file-length | readability | A | File over line limit. | kept |
| wide-struct | readability | C | Struct with too many fields. | kept |
| repeated-prefix | readability | C | Field names share prefix (`plot_width`, `plot_height`). | kept |
| mutable-struct | readability | C | `mutable struct`. | kept House style: functional code. |
| misplaced-import | readability | C | Import outside file that uses it. | moved from default · fixer Julia imports are per module, so style only. |
| c-type | readability | A | `Cint` and similar outside C calls. | kept |
| ref | readability | A | `Ref` outside C calls. | changed Exempt `f.(Ref(x), xs)` automatically. |
| jscpd | readability | G | Copied code blocks. | kept |
| forbidden-pattern | readability | A | Line matches project-defined pattern. | changed Each pattern declares its own group. |

## Rules proposed before footgun list

Proposed rules come from Julia footgun survey and from Base bug corpus of `julia-in-lean` ( julia-in-lean-rules.md ). None is built.

Covered by open work: `parametric-invariance` (`invariant-parameter`, #105), `narrow-signature` (`concrete-annotation`, #115), `untyped-container` (extend `abstract-element`, #127, to `[]` and `Dict()`).

Dropped from survey: ternary spacing (parse error), `"a" + "b"` (`jet` reports it), methods that differ only in keywords (precompile errors), `Adjoint` passed to `::Matrix` (`concrete-arg`), environment hygiene (not source code). Already covered: type instability, abstract fields, non-constant globals, boxed captures, `Float32` literals, bare `catch`.

| Rule | Group | Family | Finds | Confidence · source |
|---|---|---|---|---|
| array-literal-spacing | correctness | A | `[1 -2]` is 1×2 matrix; `[1 - 2]` is `[-1]`. Space before unary minus inside literal. | proven by shape · survey |
| wrapped-range | correctness | A | `[1:3]`: one-element vector that holds range. | proven by shape · survey |
| juxtaposition-precedence | correctness | A | `2^2x` is `2^(2x)`; `1/2x` is `1/(2x)`. Suggest explicit parentheses. | proven by shape · survey |
| shared-fill | correctness | B | `fill(zeros(3), n)`, `fill([], n)`: n references to one mutable object. | proven · survey |
| isapprox-zero | correctness | A | `x ≈ 0` or `isapprox(x, 0)` without `atol`; always false for nonzero `x`. | proven by shape · survey |
| threadid-buffer | correctness | A | Buffer indexed by `Threads.threadid()`; tasks migrate between threads. | proven by shape · survey |
| implicit-rng | correctness | A | `rand()`, `randn()` in package code without explicit RNG argument. | proven by shape · survey Pairs with RNG exemption from `!`. |
| include-twice | correctness | A | Same file included twice; second copy of its module. | proven · survey |
| eq-without-hash | correctness | C | Type defines `==` without `hash`; `Dict` and `Set` disagree. | proven · survey |
| unqualified-extension | correctness | C | Method named like `Base` function, defined without `Base.`; shadows it in module. | proven · survey |
| signed-rounding | correctness | D | `%`, `÷`, `div` on signed operands not known non-negative. `-1 % 3 == -1`; `-7 ÷ 2 == -3`. | unproven without value ranges · survey |
| inexact-conversion | correctness | D | `Int(x)` on float; throws on fractions. Suggest `round(Int, x)`. | proven type · survey |
| missing-in-condition | correctness | D | Condition whose type includes `Missing`; `if missing` throws. | proven type · survey |
| mutable-dict-key | correctness | D | `Dict` or `Set` with mutable key type; mutating key corrupts table. | proven type · survey |
| byte-index-string | correctness | D | `s[i]` with `i` from `1:length(s)`; string indices are bytes. | proven type · survey |
| mixed-signedness | correctness | D | `div`/`fld`/`mod` with one `Unsigned` and one `Signed` argument. | proven type · julia-in-lean R5 |
| bool-index | correctness | D | `Bool` scalar used as index or range endpoint. | proven type · julia-in-lean R11 |
| middle-slurp | correctness | D | `a, b..., c = t` on tuple too short for targets. | proven type · julia-in-lean R18 Guards Base bug; name affected Julia versions. |
| dict-mutation-in-iteration | correctness | E | Write to `Dict` inside loop over same `Dict`; undefined behavior. | proven when alias known · survey |
| self-alias-mutation | correctness | E | Same binding passed twice to mutating call: `append!(a, a)`. | proven · julia-in-lean R10 |
| shared-stateful | correctness | E | `Iterators.Stateful` shared by two consumers, or probed by `isempty`. | proven · julia-in-lean R9 |
| assume-effects | correctness | E | `@assume_effects` claim that inferred effects of body contradict. | proven · julia-in-lean R17 |
| soft-scope | correctness | H | Top-level loop in script assigns global; behavior differs between REPL and file. | proven · survey |
| try-scope | correctness | H | Variable first assigned in `try` and read after it. | proven · survey |
| threaded-race | correctness | H | `+=` to shared variable in `@threads` body. | proven by shape · survey |
| discarded-task | correctness | H | `@async`/`@spawn` result never waited; its errors vanish. | proven · survey |
| world-age | correctness | H | Function defined by `eval` then called in same function. | proven by shape · survey |
| nothing-compare | performance | A | `x == nothing`. Suggest `isnothing(x)`. | proven by shape · survey |
| column-major-loop | performance | A | Nested loops whose inner index is not first array index. | unproven only · survey |
| slice-copy | performance | B | Read-only slice `A[:, i]` allocates. Suggest `@views`. | proven · survey |
| broadcast-rebind | performance | B | `x = f.(y)` on preallocated `x`. Suggest `x .= f.(y)`. | proven · survey |
| splat-large | performance | D | Splat of collection with no fixed length. | proven type · survey |
| index-range | composability | A | `1:length(A)` assumes 1-based indices. Suggest `eachindex(A)`. | proven by shape · survey |
| type-piracy | composability | C | Method on function and types package does not own. | proven · survey Wrap Aqua.jl. |
| implicit-import | composability | C | Name reached through bare `using`; two packages can export it. | proven · survey Wrap ExplicitImports.jl. |
| implicit-return | readability | H | Function mixes explicit `return` with value from last expression. | proven by shape · survey |
| matrix-function | correctness | D | `exp`, `sqrt`, `^` on matrix: matrix function, not elementwise. | unproven only · survey |
| conjugating-adjoint | correctness | D | `v'` on complex data conjugates. | unproven only · survey |
| dict-order | correctness | D | `Dict` iterated into ordered output. | unproven only · survey |
| integer-overflow | correctness | E | Integer arithmetic that can wrap. Needs value ranges; julia-in-lean summaries could help later. | future · survey + julia-in-lean |

## Rules removed

| Rule | Reason |
|---|---|
| bang | Scratch code. "Returns nothing" does not mean "mutates". Replaced by `no-op` and wider `unmarked-mutation`. |
| float64 | Duplicates `float-widening` with more noise. |
| struct-constant | Works around Revise; reports good code. |
| derived-constant | Works around Revise; `const TABLE = build_table()` is good practice. |
| range-guard | Specific to one past bug; reports normal `floatmax` use. |

## Ideas from open work

Rule ideas from open PRs and local workspaces. Rewrite starts from scratch: review judges each idea, and no implementation carries over. None is accepted into plan yet.

| Rule | Group | Family | Finds | Source | Review |
|---|---|---|---|---|---|
| unwritten-undef | correctness | B | Uninitialized array not provably written in full before read; written `zeros`/`ones`/`fill` array that should start as NaN. | #128 · pedantic | ✓ keep. Reading `undef` memory is real bug; one rule for both array cases is good merge. Move `undef` part to correctness with `proven`/`unproven` split. |
| no-inbounds | correctness | A | Every `@inbounds`. | workspace no-inbounds · default | ✓ keep. Wrong index corrupts memory silently. Compiler removes checks for `eachindex` loops anyway. Fixer (workspace inbounds-fixer) only adds checks, so it is safe. |
| silent-existence-filter | correctness | A | Path filter that drops paths that do not exist. | workspace ratchet-seeding · deny | ~ narrow. Fits fail-loud style, but targets one pattern. Workspace base is stale; its other group changes are old. |
| abstract-element | performance | A | Container built with abstract element, key or value type: `Real[]`, `Vector{Real}()`, `Dict{String, Any}()`, `similar(x, Real)`. | #127 · pedantic | ✓ keep. Extend to `[]` and `Dict()`, which absorbs proposed `untyped-container`. Exempt explicit `Any` (`Any[]`, `Vector{Any}`): approved opt-out. |
| invariant-parameter | composability | A | Abstract type parameter in argument annotation without `<:`: `Vector{Real}` rejects `Vector{Int}`. | #105 · default | ✓ keep, as correctness. Method silently fails to match intended calls. Precise and cheap. `concrete-annotation` repeats it; remove it there. |
| concrete-annotation | composability | A·B | Annotation names concrete type: arguments, results, `where` bounds, public struct fields; also invariant parameters. | #115 · pedantic · fixer #116 | ~ keep, trimmed. Matches "abstract annotations intended". Drop invariant-parameter sub-check. Absorb `concrete-return`. Exempt fast-path methods beside generic sibling, as `enumerated-union` does. PR itself calls it noisy. |
| any-supertype | composability | A | Struct with supertype `Any`. | #115 · pedantic | ✗ doubtful. Most structs need no abstract parent. Rule pushes authors to invent hierarchies with one member. Abstract parent helps only when several types share methods. |
| enumerated-union | composability | A | Union of concrete types with shared supertype narrower than `Any`: `Union{Float32, Float64}`. | #99 · default | ~ change. Union of floats joins to `AbstractFloat`; suggestion calls `abstract-float` rewrite, so message and fix say `Real`. |
| abstract-float | composability | A | `AbstractFloat` where `Real` works; rejects rationals, intervals, dual numbers, units. | #125 · pedantic · fixer #126 | ✓ keep. `AbstractFloat` blocks autodiff: ForwardDiff `Dual` is `Real`. Report every `AbstractFloat` annotation; no exemption, since float-only functions can be defined for other `Real` types. `enumerated-union` reuses its rewrite. |
| collect | composability | A | Every `collect` call. | #121 · pedantic | ✗ doubtful as written. `collect` is normal way to materialize iterator, for example before `sort!`. Narrow to `collect` of array (pointless copy) or of value used once (iterate lazily). |
| literal-array | composability | A | `Vector{T}(undef, …)`, `similar(Vector{T}, …)`. Suggest `similar(x, T, dims)`. | #113 · default · fixer #114 | ~ keep one. Same goal as `similar-array`: keep caller's array type (GPU, static). Useful only when template exists. `similar-array` checks that; prefer its logic. |
| similar-array | composability | A | `Vector`/`Matrix`/`Array` constructor where annotated template array exists. | workspace similar-arrays · pedantic | ~ keep one. More precise of the two. Merge with `literal-array`. |
| dims-keyword | readability | A | Call or broadcast with `dims` keyword. Suggest `eachslice`, `eachrow`, `eachcol`. | #121 · pedantic | ✗ doubtful. `sum(A; dims = 1)` is idiomatic and fast. `sum.(eachcol(A))` returns different shape and can be slower. Rationale needed. |
| banned-name | readability | A | Names project bans by word or suffix. | #120 · default | ✓ keep. Fits "descriptive names". Share one config table with `forbidden-pattern`. |
| while-true-return | readability | A | `while true` loop that leaves by `return`. | #118 · pedantic | ~ taste. Loop-and-a-half (read, test, return) is clear in this form. Rewriting it often duplicates first read. Keep only if you prefer it. |
| irrational-constant | readability | A | Hand-written constants that IrrationalConstants.jl names: `sqrt(2π)`, `log(2π) / 2`, normal density. | workspace irrational-constant · pedantic | ✓ keep. Clearer, and exact at every float width. Fixer in workspace irrational-fixer. |
| comment-docstring | readability | A | Function with comment block directly above and no docstring. | workspace comment-docstring · pedantic | ✓ keep. Enforces "docstrings at top of functions". |
| file-module | readability | A | File that is not exactly one module around its content; module without docstring. | workspace file-module · pedantic | ✗ doubtful. Julia packages usually `include` files into one module. One module per file adds import boilerplate everywhere. Keep module-docstring part. |

## Early decisions

### Fix tiers (proposal)

Each fix declares tier; setting picks highest tier applied. `safe`: behavior unchanged. `likely`: types or dispatch may change. `breaking`: API changes; ratchet absorbs new findings.

### Project kind (proposal)

Preset over groups and fix tier. `library`: all groups, `likely` fixes. `application`: correctness and performance, `breaking` fixes (no downstream). Infer `application` when Project.toml has no `name`; else require setting.

### No tests (decided)

Corset never reads or runs package tests. Signatures come from annotations: marker types for generic arguments, declared type otherwise. `::Any` arguments infer as `Any`.

### Groups (decided)

`correctness`, `performance`, `composability`, `readability`. `pedantic` removed.

### `!` scope (decided)

Argument and global writes. IO and RNG exempt. Memo caches exempt with cheap proof only.

### Annotations (decided)

`::Any` is explicit opt-out. Abstract argument types are intended.

### constant-array (decided)

Keep. It prevents pointless allocations.

### Borrow checking (decided)

Defer. Revisit for concurrency rules.

### Strictness wording (open)

Setting names `"proven"` and `"unproven"` are draft. Confirm meaning: report proven problems only, or also unproven safety.

### one-letter exemptions (open)

`i` allowed. Decide `j`, `k` for nested loops, and `T` for type parameters. Prefer role names (`left`, `right`) over `num1`, `num2`.

### specialization-blowup (open)

Replace `overspecialized-anon-fun` with measured specialization count?

### concrete-return (open)

State what it must catch, or remove it.

### Rule names (decided)

Follow `main`: `unstable-variable`, `unstable-return`, `*-anon-fun`.

### No `float64` check (decided)

Rewrite has no check for `Float64` tokens. `float-widening` covers real cases.

### Union width (decided)

One policy for inferred locals, results and struct fields; argument annotations exempt. `Nothing` and `Missing` are free. Members from one module other than Base or Core form variant group. Allow at most one member outside that group.
- Pass: `Union{Circle, Square}`, `Union{DepA.Leaf, DepA.Node}`, `Union{Float64, ParseError}`.
- Report: `Union{Int, Float64}`, `Union{String, Symbol}`.
- Report where union is created: merge in package method, or package declaration.
- Union forwarded unchanged from dependency passes; `strictness = "unproven"` reports it.
- Message suggests sum-type package (Moshi.jl, SumTypes.jl).
- Baseline keeps existing findings from failing CI.

### Public struct fields (decided)

`concrete-annotation` accepts only type parameter (`x::T`) as fix, so `abstract-field` never reports result.

### Explicit `Any` (decided)

`::Any`, `Vector{Any}`, `Any[]` are approved opt-outs everywhere. Container rule (`abstract-element` idea) exempts them.

### `similar-array` (O1) (decided)

One rule replaces `literal-array` and `similar-array` ideas. Report hard-coded `Vector`/`Matrix`/`Array` construction everywhere. With template array: autofix to `similar(template, T, dims)`. Without template: message teaches caller-supplied template or array type; autofix adds parameter in `breaking` tier. Covers `zeros`, `ones`, `fill`; combined fix with `constant-array` and `unwritten-undef` through F1.

### `type-disruption` engine (decided)

Principle: values from outside inputs are weak. Literals, constants and globals must not change result type. Inputs combine by normal promotion. Same rule as NumPy 2 for Python scalars.

| Kind | Inputs combine as | Literal or constant | Example finding |
|---|---|---|---|
| Numbers | normal promotion; `Int32` with `Int64` gives `Int64` (pass) | weak: must not widen | `x::Int32 * 2` gives `Int64` |
| Arrays | keep container kind; element types promote | fresh `Array` must not take over container | `x::JLArray .+ zeros(n)` gives `Array` |
| Strings (later) | `String` is correct common type | literal is `String` already | rare; Julia already does this |
| Dicts, sets (later) | keep container kind; key and value types promote | as for arrays | rare |

- Marker types : one per kind. Numbers use `𝒯 <: Real`; arrays use marker array type. Each marker is ordinary well-behaved type with normal promotion (`promote_rule(𝒯, Int) = 𝒯`). Base code runs on it unchanged.
- Inference : infer each package method with markers in place of generic arguments (`::Real`, `T <: Real`, `AbstractArray{T}`). Use native inference and its cache. No JET, no Cthulhu, no custom interpreter.
- Scan (family D, package methods only):
- Arithmetic or promotion call mixes marker with foreign number type (`x * 2`, `x + 0.5`): report, even when result is still marker.
- Value derived from inputs ends with type other than marker: report.
- Branch on type (`x isa Float64`, `T === Float32`): report as `unproven`.
- Why marker : Base has fast paths for `Float32` and `Float64`. Real float probe takes them; marker takes only generic path, same as user number type.
- Base : assume Base callees preserve types; analysis is sound only modulo Base. Optional concrete probes (`Int32`, `Float32`) catch Base-caused widening such as `middle(::Int32)` → `Float64`. Collect real Base widening bugs for upstream report.
- Scope : version 1 covers numbers and arrays; replaces type checks behind `float-widening` and `similar-array`. Strings and dicts need only new marker and result rule; engine stays same. Interfaces.jl can declare each kind's contract.
- Cost (rough estimate, unbuilt): number marker 100–200 lines (promotion, conversion, arithmetic, comparison, `one`/`zero`, `float`, math functions); expect to add methods until inference runs clean on real packages. Mixing check 100–200 lines. Source mapping through TypedSyntax.jl.
- No tests : markers come from annotations. `::Any` arguments infer as `Any`. Unannotated methods are skipped; `annotation` reports them.
- Syntax check stays for `similar-array` without template. Shared fix helper finds in-scope type source (`T`, `eltype(x)`, template array).

### Annotation rules overlap (conflict)

`concrete-annotation` covers invariant parameters (`invariant-parameter`) and results (`concrete-return`). Merge into one rule with sub-checks?

### Suggested abstract type (decided)

Always suggest `Real` for floats. `enumerated-union` calls `abstract-float` rewrite directly: `float_to_real(typejoin(members))`. Property test guards all rules: applying any fix never creates new finding. Revisit general mechanism only if test keeps finding conflicts.

### Name bans (decided)

`banned` merges `banned-name` and `forbidden-pattern` into one config list. Entry holds `pattern` or `name`, plus `reason`.
Rule level covers every entry, like Clippy `disallowed_methods`; per-entry group was dropped.

### JET (open)

Proposal: test-only oracle. Typed IR from native compiler at lint time.

## Coverage of old rules

Frozen: footgun and check names as of design split. Current catalog lives in footguns.toml and rules.toml.

| Source | Legacy rule | Footguns | Rule | Note |
|---|---|---|---|---|
| main | `unstable-variable` | F17 Variable, result or closure capture with vague inferred type | `vague-type` |  |
| main | `unstable-return` | F17 Variable, result or closure capture with vague inferred type | `vague-type` |  |
| main | `unstable-anon-fun` | F17 Variable, result or closure capture with vague inferred type | `vague-type` |  |
| main | `runtime-dispatch` | F27 Call resolved at run time | `runtime-dispatch` |  |
| main | `recursion-limit` | F29 Recursion with argument types that nest each call | `growing-recursion` |  |
| main | `float-widening` | F5 Literal or constant changes input type | `type-disruption` |  |
| main | `float64` | F5 Literal or constant changes input type | `type-disruption` | Duplicate. |
| main | `abstract-field` | F18 Struct field with vague type | `vague-type` |  |
| main | `mutable-struct` | F19 Mutable struct where immutable works | `mutable-struct` |  |
| main | `wide-struct` | F78 Struct with too many fields | `wide-struct` |  |
| main | `repeated-prefix` | F79 Related fields belong in nested struct, table or array | `field-prefix` |  |
| main | `repeated-statement` | F60 Same statement twice in block | `duplicate-statement` |  |
| main | `return-type` | F26 Behavior depends on inference result | `inference-dependent` |  |
| main | `concrete-arg` | F15 Overspecified type blocks generic callers | `overspecified-type` |  |
| main | `concrete-return` | F13 Result annotation converts instead of checking<br>F71 Argument or result without type | `annotation`, `result-conversion` |  |
| main | `annotation` | F71 Argument or result without type | `annotation` |  |
| main | `c-type` | F81 C types outside C calls | `c-type` |  |
| main | `ref` | F19 Mutable struct where immutable works | `mutable-struct` | `Ref` as C helper dropped; struct of `Ref`s kept. |
| main | `one-letter` | F72 One-letter name | `one-letter` |  |
| main | `file-length` | F77 File too long | `file-length` |  |
| main | `forbidden-pattern` | F82 Project-banned name or pattern | `banned` |  |
| main | `where-return` | F4 `where` after result annotation binds result type | `where-binding` |  |
| main | `constant-array` | F39 Never-written constant array allocates | `constant-array` |  |
| main | `nan-initializer` | F34 Placeholder value looks like data after partial fill | `unwritten-element` |  |
| main | `broad-catch` | F59 Catch handles every error | `broad-catch` |  |
| main | `quadratic-scan` | F43 Search inside loop over same collection | `quadratic` |  |
| main | `quadratic-vcat` | F44 Fold concatenates one piece at a time | `quadratic` |  |
| main | `misplaced-import` | F67 Import placed in file that does not use it | `misplaced-import` |  |
| main | `hidden-input` | F55 Hidden input: mutable global, `ScopedValue`, global RNG | `hidden-input` |  |
| main | `non-public-access` | F66 Use of other module's internal name | `internal-access` |  |
| main | `unmarked-mutation` | F53 Function writes argument or global without `!` | `bang-convention` |  |
| main | `bang` | F53 Function writes argument or global without `!`<br>F54 Call has no effect and result is unused | `bang-convention`, `unused-call` | Split into missing `!` and no-op call. |
| main | `impure-anon-fun` | F56 Anonymous function impure: captures mutable state<br>F57 Closure rebinds captured variable; `Core.Box` | `boxed-capture`, `impure-lambda` | Split: impure capture, boxed capture. |
| main | `overspecialized-anon-fun` | F30 Too many specializations on `Function` or `Type` argument | `specialization-blowup` |  |
| main | `jscpd` | F76 Copied code block | `duplicate-code` |  |
| main | `jet` | F83 Call can never succeed | `never-succeeds` | Cheap cases in D scan; JET for rest. |
| main | `fatou` | — | — | External; not reviewed. |
| main | `nothing-return` | — | — | Dropped. |
| main | `non-atomic-write` | — | — | Dropped. |
| main | `struct-constant` | — | — | Dropped: Revise workaround. |
| main | `derived-constant` | — | — | Dropped: Revise workaround. |
| main | `range-guard` | — | — | Dropped: one past bug. |
| open work | `unwritten-undef` | F33 Uninitialized element read before write | `unwritten-element` |  |
| open work | `no-inbounds` | F37 Index safety removed without proof | `unverified-inbounds` |  |
| open work | `abstract-element` | F21 Empty literal has `Any` element type | `untyped-empty` |  |
| open work | `invariant-parameter` | F14 Invariant parameter rejects intended arguments | `invariant-parameter` |  |
| open work | `abstract-float` | F15 Overspecified type blocks generic callers | `overspecified-type` |  |
| open work | `concrete-annotation` | F13 Result annotation converts instead of checking<br>F15 Overspecified type blocks generic callers | `overspecified-type`, `result-conversion` |  |
| open work | `enumerated-union` | F15 Overspecified type blocks generic callers | `overspecified-type` | Kind of `overspecified-type`: `Union{Int16, Int32, Int64}` to `Integer`. |
| open work | `literal-array` | F16 Hard-coded `Array` drops caller's array type | `type-disruption` |  |
| open work | `similar-array` | F16 Hard-coded `Array` drops caller's array type | `type-disruption` |  |
| open work | `banned-name` | F82 Project-banned name or pattern | `banned` |  |
| open work | `irrational-constant` | F6 Float constant where irrational exists; promotes generic code | `type-disruption` |  |
| open work | `comment-docstring` | F74 Comment where docstring belongs | `docstring` |  |
| open work | `while-true-return` | — | — | Dropped. |
| open work | `collect` | F16 Hard-coded `Array` drops caller's array type<br>F32 Temporary array built only to be consumed once | `temporary-array`, `type-disruption` | Goal: `collect` returns `Vector`, drops array type. |
| open work | `file-module` | F80 Module without docstring | `docstring` | Docstring part only. |
| open work | `silent-existence-filter` | — | — | Dropped: reasonable code. |
| open work | `any-supertype` | F84 Public struct has no abstract supertype; users cannot extend | `closed-struct` | Extensibility. |
| open work | `dims-keyword` | F32 Temporary array built only to be consumed once | `temporary-array` | Stay-lazy goal; `dims` itself fine. |


## Adversarial review findings

Codex reviewed design page; each finding with its outcome.

| # | Finding | Outcome |
|---|---|---|
| 1 | `infer_effects` gives no per-argument writes | Fixed: own bottom-up write summary (S5, `!` convention). Unknown callee gives `possible`. |
| 2 | Integer literal widening also guards overflow; user promotion rules | Rule kept by owner. Definite via Base counterexample; user promotion rules out of scope. |
| 3 | Cache keys miss method-table, preferences, extensions, generated methods | Fixed: compiler dependency record, global key additions, `@generated` depends on package. |
| 4 | Escape analysis skips small numbers | Fixed: own data-flow pass to returns and stores. |
| 5 | Unannotated methods skipped | Clarified: analyzed through callers; uncalled ones skipped and reported by `annotation`. Annotation rule kept by owner. |
| 6 | External macro output invisible before load | Fixed: expanded code only after load; unmapped location goes to coverage line. |
| 7 | F23 claimed to error | Rejected: Julia 1.13 silently creates separate function (tested). |
| 8 | F15 fast paths; small unions fast; `Real` worsens inference | Fast-path exemption restored. F20 split into `ad-hoc-union` (readability). `Real` claim rejected: arguments specialize anyway; fields get type parameter. |
| 9 | Array lifecycle cannot prove general reads | Fixed: definite only for straight-line patterns. |
| 10 | Temporary environment may change versions; triggers need loading | Fixed: target versions preserved or fail loud; triggers loaded. |
| 11 | 90% gate contradicts `definite`; fixes not behavior-checked | Fixed: false definite blocks check; `safe` fixes run before and after. |
| 12 | Concurrency non-goal contradicts phases; stale counts | Fixed: non-goal is race and ownership analysis; counts generated. |
| 13 | Method ambiguity missing | Fixed: F94 `method-ambiguity` (Aqua.jl). |

## Phase 0 design review

Spike reports: `spikes/s1-stand-in-inference` to `spikes/s5-effect-summary`, file `REPORT.md` each.

| Spike | Finding | Outcome |
|---|---|---|
| S1 | Opaque function result truncates frames | Function stand-in returns `Any`. |
| S1 | Unannotated entry points leave most methods without stand-in | Family D keeps explicit worklist of frames reached from stand-in callers. |
| S1 | `Union{}` alone cannot drive `never-succeeds` | Re-dispatch on real types; deepest frame only; `Int`-only signatures `possible`. |
| S1 | Integer-literal findings were all index arithmetic | Disruption converted away downstream is exempt; first version exempts indexing. Exact rule after phase 4. |
| S1 | Stand-in loses `Float32` special cases | Stand-in copies result-type special cases; ambiguity test. |
| S2 | Lowering keeps no call-site provenance on 1.13 | Macro-written code maps to nearest in-definition line. |
| S2 | Not every finding has byte span | `Span` gains precision; definite typed finding needs validated span. |
| S2 | CodeTracking front end loses closures and offsets | Vendor TypedSyntax mapping algorithm onto L1 tree. |
| S3 | Macro expansion needs loaded package | L2 runs after L3; lowering per top-level form in include order. |
| S3 | Base macros give lines only | Own replacement expansions for common Base macros; precompile workload. |
| S3 | F63 needs no scope facts | F63 moves to family A. |
| S4 | Argus.jl is MIT; slower by search order | Use Argus behind own root-kind walk; upstream index later (owner approves PR). |
| S4 | 5× legacy budget includes Julia startup | Budget measures Corset ready to findings out; startup and target load excluded. |
| S5 | Callee summaries need dependency code | Rule reworded: analysis reads dependency code; findings stay in package. Base summaries cached per Julia version. |
| S5 | `possible` comes only from unknown callees | `possible` effect findings off until dispatch resolution passes gate. |
| S5 | Exemption list incomplete | Lazy-init caches, task-local state, locks, error paths, other modules' globals exempt; IO decided by declared type. |
| S5 | Error-only `!` method flagged spurious | Exempt from F86. |

### Phase 0 review: adversarial pass

| # | Finding | Outcome |
|---|---|---|
| 1 | Syntax-only F36 can be false `definite` (`CircularDeque`) | Fixed: syntax-only F36 is `possible`. |
| 2 | Error-path exemption hides write before caught throw | Fixed: only fresh local objects exempt; argument and global writes stay. |
| 3 | 5× target compares different scopes; effects too slow | Fixed: remeasure legacy in same scope; effects phase gets own budget. |
| 4 | Argus candidate-node speed unmeasured | Fixed: benchmark first in phase 2. |
| 5 | Range exemption rests on open S1 question | Fixtures added. Rejected "keep possible": exemption covers only uses proven index-only; rest reports as before. |
| 6 | Family B on L1 and L2 | Fixed: B on L1 only. |
| 7 | Soft-scope predeclaration missing | Fixed: Scope contract declares globals in include order. |
| 8 | "Every package method" overstates coverage | Fixed: eligible methods; coverage line counts rest. |
| 9 | F1 needs whitespace; Argus ignores trivia | Fixed: F1 reads source bytes. |
| 10 | S5 percentage wrong | Fixed: per-package shares. |
| 11 | LintApp check source stale | Fixed: JuliaWorkspaces named. |

### Layer audit after first family A checks

Principle: rule waits for layer that owns its facts. Removed syntax versions and fixtures stay in `main` at `3cb1383` (`src/checks`, `test/ui`).

| Rule | Problem | Outcome |
|---|---|---|
| `quadratic` | Grouped F43 (D) with F44 (A); syntax scan ignored collection type | Split: `loop-search` (F43, D), `repeated-concat` (F44, A). Syntax scan removed. |
| `shared-fill` | Constructor list guessed mutability | F35 moves to D. Fix tier `manual`: comprehension changes code that shares on purpose, and `fill(x, -1)` throws where comprehension returns empty. |
| `one-based-range` | Syntax `possible` reported missing type facts as finding; `Vector` argument is always 1-based | F36 moves to D. |
| `loop-order` | Memory order depends on array type (`Adjoint`) | F42 moves to D. |
| `non-exhaustive-match`, `unreachable-arm`, `wildcard-arm` | Variants need loaded ADT | Dropped as F89–F91. First two belong upstream in Moshi `verify/`: macro expansion already loads ADT. `wildcard-arm` is opinionated and needs per-rule default levels; dropped. |
| `c-type` | Local variable named `Cint` gives false finding | Kept in A. `Cint === Int32`, so only syntax sees alias. Import `Cint as CI` still names `Cint` in import line. |
| `untyped-empty`, `annotation` | Fixer needs inferred element or argument type | Detection stays A. Fixer reads L4 when it ran; otherwise fix is `manual`. |

### Rename: check to rule

"Check" named three things: `corset check` command, `Corset.check()` pipeline entry, and one unit of config. Unit is now "rule", as in Ruff. Command and entry point keep verb `check`. Argus wrapper `Rule` became `IndexedPattern`: it holds only pattern and root-kind index, while Argus `Rule` is whole named rule.

### Doubt test: compiler as yardstick

"Perfect analysis" left budgets ambiguous: dispatch over Corset's 4-candidate budget became blind spot. Compiler dispatches such call at run time, which is real code property. Test now asks whether compiler resolves doubt; Corset limits match compiler limits (`max_methods`, union splitting).

### Rename: families and layers to stages

Letters and layer numbers became one list of named stages. Map for older text: A and L1 `syntax`; B `lifecycle`; C and L3 `package`; H and L2 `scope`; D and L4 `inference`; E and L5 `effects`; G `external`.

### `lifecycle` after `effects`

Array rules hinge on whether callee writes array. Syntax alone treats every call as escape, or needs hand-written list of non-writing Base functions. `lifecycle` now reads callee writes from `effects` summaries and ships in phase 5; scripts get it with definitions-only load.

### Macro code

Self-lint matched rule patterns inside Argus `@pattern` bodies, which are data. Rules now follow Clippy: they read code as written, macro arguments included, and code that package macros write. Code that other packages' macros write gets no findings, since package cannot fix it; earlier text reported it marked upstream. Syntax stage skips quoted code outside `$` interpolation. Shelved: skip macro arguments Julia rejects as written (lowering error such as `{x}`, or call no Base method takes such as `x ~ Normal()`). Lowering belongs to `scope` and method tables to `package`, so syntax stage would be second producer. Stopgap until then: skip macro arguments with `{}`, which lowering always rejects; revisit with general check.

### File discovery

`corset check .` walked every directory: hidden `.worktrees` copies, nested packages and test fixtures. Discovery now follows Cargo: package root gives entry files and their include closure, so fixtures that tests read as data stay out. Include with computed path is blind spot, since loading resolves it; coverage line lists it. `.gitignore` support waits in later work.

### Fix properties

Supposition properties found four causes of fix bugs.
JuliaSyntax keeps grouping parentheses as trivia of parent. Fixes that pasted child source dropped them: `(a + b)/2x` became `a + b/(2x)`. `source` now keeps them.
`world-age` rewrote method signature after `eval` as call. `docstring` fired in function bodies, where docstring is plain string. `duplicate-statement` compared docstrings.
Exempt from no-new-finding property: rules that compare statement with neighbor. Fix can rewrite statement into neighbor's text; duplicate existed in meaning before.

### Speed test

Phase 2 benchmark: matcher design holds; `one-letter` alone cost 180–570 ms per 10,000 lines.
Perf test (`test/perf.jl`) found six rules with cost quadratic in function size. Causes:
`SyntaxNode` `hash` walks whole subtree, so set keyed by function node hashed its body per name.
`children_of` copied child vector; `source` scanned parent children for grouping parentheses; `docstring` copied rest of file per definition.
Fixes: identity keys, read-only children without copy, grouping parentheses found once at parse.
Garbage collector makes linear code look quadratic: full collections scan live heap. Test times with collector off and checks allocation ratio.

### Reference linter map

Mapped 101 rules: ReLint.jl 50 (commit 6107942), LintApp.jl 51 (JuliaWorkspaces 13.5.0).
Covered 1, gap 2, later stage 15, dropped 2, no footgun 81. Gaps: `double-include` misses include loop through entry file and `joinpath(@__DIR__, …)` paths.
Most no-footgun rows are RelationalAI conventions, caution markers (`ccall`, `finalizer`: `banned` entries) or errors Julia reports itself.
Owner accepted all 13 proposed bug classes. General rule wins where one check covers another as special case:
- F96 `unreachable` covers repeated branch condition and statement after exit.
- F97 `unused-literal` covers detached docstring and other literal statements.
- F103 `unused-binding` covers unused local, argument and `where` parameter.
- F104 joins F22 in `operator-consistency` (was `eq-without-hash`).
- F98 `unguarded-release` covers `unlock`, `release` and `close` outside `finally`.
- F99 `pinned-task` covers `@async`, `Task` and `@threads :static`.
- F101 `process-state` covers `ENV` writes and `cd`.
Parse errors become `deny` findings outside rule table, as in Ruff.

### Phase 3 design

Reread `architecture.md`, `findings.md`, `stages.toml` and package-stage footguns before phase 3.
Julia 1.13 check: overwritten method makes precompilation fail, then Julia loads package without cache. Overwritten method leaves method table.
F24 widened to every overwrite with same positional signature; rule `keyword-overwrite` renamed `method-overwrite` before it shipped. Packages: syntax tree pairs both definitions with surviving method. Scripts wait for definitions-only load.
F76 `duplicate-code` moves to later: jscpd needs Node at lint time.
Dropped `Corset.check()` inside `runtests.jl`. Test code changes method table, and `--code-coverage` changes optimized IR; principle says code that ran before Corset changes speed only.
Temporary environment is nameless and develops target by path: copied named project would load target from cache directory.
Load failure is `load-error` finding, as `parse-error`.

### Phase 3 design: adversarial pass

Codex review of phase 3 design found four problems; all accepted:
- `@v#.#` sits in default load path, so ambient packages could supply target, triggers or methods. Command line now always relaunches with `JULIA_LOAD_PATH` set to temporary environment and `@stdlib`.
- Overwrite without keywords keeps earlier keyword sorter; F24 note says so.
- F88 reads Project.toml only; it moves to `syntax` stage, so load error does not hide it and check loads nothing.
- Piracy fixture changes method table for later UI cases; such fixtures run in fresh process.

### Phase 3 code review: adversarial pass

Codex reviewed phase 3 code (PRs #175 to #195) by trace only. Each finding got regression test before fix.

| # | Finding | Outcome |
|---|---|---|
| 1 | `overspecified-type` fix can make call ambiguous, or give two methods one signature | Fixed: fix is `likely` when widened method and each other method of function, widened too, are disjoint or nested. Otherwise fix is manual. |
| 2 | Checked path through symlink loses method sites | Fixed: check resolves real path, where relaunch develops package. |
| 3 | Own `IteratorSize` that returns `HasLength` hides missing `length` | Fixed: inference finds trait. `HasShape` needs `size` too. |
| 4 | Extension trigger that throws ends run with internal error | Fixed: blind spot "extension trigger did not load". |
| 5 | Environment cache ignores Project.toml of path dependencies | Fixed: cache key reads Project.toml of Manifest path entries and test `[sources]` paths. |
| 6 | Bare `using` lookup matches innermost module name only | Fixed: ExplicitImports.jl rows give full module path of statement. |
| 7 | Removing only `using X: a` stops loading `X` | Fixed: removal of only import that loads package is manual. |
| 8 | `misplaced-import` move changes load order, but fix is `safe` | Fixed: fix tier is `likely`. |
| 9 | Own `IteratorEltype` that returns `HasEltype` hides missing `eltype` | Fixed: inference finds trait. |

### Phase 3 corpus review

Corpus run (Distances, DataStructures, JSON and two private projects) gave these decisions:
- `juxtaposition` (F3) moves to readability group. Code means what Julia parses; risk is reader misreading it. Clippy `precedence` is style lint too.
- `shadowed-base` (F23) is definite only for operators and Base interface functions on package types. JSON.jl shadows `parse`, `print`, `skip` and `iscntrl` on purpose; intent is doubt in code, so other shadows are possible.
- `one-letter` and `annotation` stay as they are, though noisy: 1130 and 1044 findings on DataStructures.
- Real DataStructures.jl bugs went upstream as issues #998 to #1001: `==` without `hash`, broken `enumerateall`, iterators without `eltype`, `empty(::DefaultDictBase)`.
- `enumerateall` broke on `a || b && return` without parentheses; this backs mixed `||`/`&&` rule.

### Relaunch keeps fewest Manifest pins

Phase 3 design kept every target Manifest version, so any compat clash between Corset and target ended run with exit 2.
Corpus project pinned Aqua 0.8.18; Corset needs 0.8.19, so Corset checked nothing there.
Relaunch now moves packages Corset shares with target, within target compat, and coverage line counts each move as blind spot.
Moved dependency changes code rules read, but compiler would use pinned version: doubt test makes it blind spot.
Rejected: split Corset into analysis and command-line packages. It removes only ArgParse, Configurations and JSON from relaunched process.

### Phase 4 design

Reread `types.md`, `pipeline.md`, `stages.toml`, S1 and S2 reports before phase 4.
- Stand-in function returns `Any`: inference barrier keeps later code analyzed. Opaque result type truncated frames in S1.
- Stand-ins copy model special cases that change result type: `sum`, `prod` and `factorial` widen `Int32` to `Int`. Sweep over Base functions found them.
- Accepted stand-in differences: range of float stand-in stores stand-in, `Float32` range stores `Float64`; stand-in has field `model`, primitive model has none.
- Source mapping: vendor TypedSyntax.jl `map_ssas_to_source` (MIT) onto Corset's own JuliaSyntax parse, with closure and do-block root patch. CodeTracking front end stays out.
- Stage facts: per analyzed method and stand-in signature, typed IR before inlining (`typeinf_ircode`, pass `"CC: COMPACT_1"`), so literals stay call operands. Worklist adds package methods reached from analyzed frames.
- Blind spots: method without stand-in for argument; generated function that inference refuses; stand-in gap (call fails on stand-in, succeeds on model type).
- Compiler internals (`typeinf_ircode`, pass name, `jl_type_intersection_with_env`) pin per Julia minor version; tests catch patch changes.
- Per-method disk cache moves to later. Findings cache gives unchanged rerun under 1 s; measure cold run against speed budget before building per-method cache.
- PR order: stand-ins; signatures; `inference` stage facts and source map; cold-run benchmark on corpus; `never-succeeds`; `type-disruption` and `intermediate-widening`; findings cache; other inference rules by group; `annotation` fixer.
- Cold-run benchmark is go/no-go: measure same scope as legacy baseline before any rule group lands.

### Phase 4 design: adversarial pass

Codex review of phase 4 design found eight problems:

| # | Finding | Outcome |
|---|---|---|
| 1 | `never-succeeds` gives false `definite` when callee has method for other type within bound (`g(::UInt64)` from `x::Integer`) | Accepted: callee method that intersects declared argument type gives `possible` (F83). |
| 2 | Typed cache misses edits in path dependencies | Accepted: key hashes files of Manifest `path` entries and `[sources]` paths. |
| 3 | Callee check alone accepts swapped spans of two calls to one callee; generated output maps to unrelated source | Accepted: gate also checks argument count and source order; generated, macro and compiler-made statements stay at line precision. |
| 4 | Accepted stand-in differences (range storage, `model` field) can make `result-conversion` wrong | Rejected for ranges: element type agrees, only storage parameters differ. Reflection on stand-in sees wrapper; inference stage treats its result as opaque. |
| 5 | Union facts merged across stand-in signatures report unions no call produces | Accepted: union policy reads one signature at a time. |
| 6 | Array stand-in has `OneTo` axes, so F36 sees one-based array where bound allows offset axes | Accepted: axis and memory-order rules read declared argument type for stand-in arguments. |
| 7 | Findings cache does not shorten first run; cold budget unchecked | Accepted: cold-run benchmark after source map, as go/no-go before rules. |
| 8 | `scope` runs before `inference` in pipeline but ships in phase 6 | Accepted: stage not built yet gives no facts; no rule reads it until it ships. |

### Phase 4 implementation notes

- `inference` stage runs `typeinf_frame` on unoptimized code, in place of `typeinf_ircode`. TypedSyntax.jl maps unoptimized statements to `syntax` stage nodes, and literals stay call operands.
- TypedSyntax.jl is dependency, not vendored copy.
- Closure and do-block root patch is not built: package stage skips methods whose names start with `#`, so no closure body is analyzed method.
- Findings cache lands before `never-succeeds`. First version stores whole analysis per checked path; key hashes every input file by content.
- `repr` names types relative to `Main` imports, so relaunching and relaunched processes printed flags differently. Key hashes serialized flags.
- `Base.julia_cmd()` copies coverage flags into relaunched process, which then wrote `.cov` files into hashed trees after it stored entry. Relaunch turns coverage and allocation tracking off.
- Loading DataStructures invalidated 45 Corset method instances through abstract inferred types. Concrete containers and two inference barriers fix it: cold check inference falls from 1.32 s to 0.63 s.
- Cache hit, whole process: 2.2–2.6 s against 4.8–7.6 s without cache. Corset load takes 1.3 s; Pkg and REPL take 0.3 s of it, and only environment build needs them.
- `never-succeeds` reads `failing` fact: reached call statement that inference gives `Union{}`. Engine computes `inference` stage only when inference rule is on.
- Throw helper counts as explicit throw: `throw`, or function each of whose methods infers `Union{}` on declared signature (`error`, `@enum` argument check).
- Keyword and splatted calls name inner callee. Constructor with unknown parameters names its type: `DefaultDictBase{K,V,F}(...; passkey)`.
- Inference wraps unreached statements in `Core.Const`. TypedSyntax.jl maps only statements later code reads, so it skipped failing calls; stage maps unwrapped copy.
- TypedSyntax.jl maps no call with string literal as last argument: `skipped_parent` skips `quote` and `...` wrappers, and `string` node is neither. Such call keeps line span. Filed as JuliaDebug/Cthulhu.jl#715; call that never returns maps to no node, #716.
- Lowering gives method for omitted defaults first body line. Stage puts its statements on definition line, which holds defaults.
- Unbounded array argument gets `ArrayStandIn{Any}`, so calls on its elements (`zero(Any)`) give `possible` findings.
- Undefined global infers `Any` on Julia 1.13, so `never-succeeds` does not report it.
- Corpus: DataStructures 1 `definite` (`empty` of `DefaultDictBase`) and 1 `possible` (`SortedSet{K,Ord}()` default ordering fails `Ord`); both reproduce. Distances 12 `possible`, from `Any` elements. JSON none.
- Coverage line listed 930 DataStructures blind spots. Text report now lists three per cause; JSON and SARIF list each one.
- Method store keeps stage facts per method and signature; rules run each time. Design planned file hashes of reached methods as dependencies.
- File hashes missed macro output: expansion lands in caller's file and leaves no compiler edge. Entry now records lowered code of each method inference read.
- Lowered code also covers `@eval` code and closure names: closure that edit renumbers has other code. Edit of one method invalidates only entries that read it.
- Generated code depends on generator and its callees, so entry records generated code per instance; run calls generator again to check it.
- `@enum` value made serializer throw in package shape. Shape serializes only plain constants: numbers, strings, symbols and immutable structs of those.
- Shape serialized tuple per struct layout and compiled serializer once per tuple type: 1.9 s on DataStructures. `Vector{Any}` and field loop fix it.
- SparseArrays.jl `_cat` invalidated `line_starts` (`vcat` of number and vector) and every caller: package and inference stages recompiled after trigger load. Loop fixes it.
- ChainRulesCore.jl `promote_rule` invalidates JuliaSyntax.jl line lookup, and with it 98 Corset instances: rules, config, discovery, inference. Not fixed yet.

### Phase 4 cold-run benchmark

Go/no-go result: Corset is 2.9–6.7× faster than legacy cold; budget is 5×. Table and numbers: `plan.md`, speed budget.
Causes found and fixed:

| Cause | Cost before fix | Fix |
|---|---|---|
| Closure over type value compiles once per value when it escapes to `filter`, comprehension or generator | `Signatures` 38 s on DataStructures; `missing-interface` and `shadowed-base` once per struct or function | Loops (#208, #210) |
| `method_sites` sort printed both signatures in each comparison | 6.6 s on DataStructures | Print only on tie (#209) |
| Precompile workload ran script only | Package stages, rules, ExplicitImports.jl and stand-in inference compiled at first package run | Workload runs package stages and rules on Corset itself, then `inference` stage on `PackageSample` (#210) |
| `Iterators.product` over splatted options compiled once per argument count; TypedSyntax.jl literal lookup compiled once per literal type | 0.1–0.7 s per package | Odometer loop; sample spells literal of each type (#211) |

Not fixed: loading DataStructures invalidates 263 method instances, Corset entry points among them, and costs 1.2 s of inference again. Chains run through TOML and JSON writes of abstract `Dict` types, and ExplicitImports.jl internals.
Decision: stand-in inference stays. Per-method disk cache joins PR order after findings cache.
