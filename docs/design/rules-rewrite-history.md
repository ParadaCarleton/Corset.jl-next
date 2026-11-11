# Corset rewrite: old rule names

Record of rules on main, ideas from open work, and early decisions that use old names.
Design page `rules-rewrite.html` replaces them with footguns and checks.

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

### Name bans (conflict)

`banned-name` and `forbidden-pattern` both ban text by config. Merge configs?

### JET (open)

Proposal: test-only oracle. Typed IR from native compiler at lint time.

## Coverage of old rules

<!-- coverage -->
| Source | Old rule | Footguns | Check | Note |
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
| main | `concrete-arg` | F15 Concrete annotation blocks generic callers | `narrow-signature` |  |
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
| main | `unmarked-mutation` | F53 Function writes argument or global without `!` | `missing-bang` |  |
| main | `bang` | F53 Function writes argument or global without `!`<br>F54 Call has no effect and result is unused | `missing-bang`, `unused-call` | Split into missing `!` and no-op call. |
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
| open work | `abstract-float` | F15 Concrete annotation blocks generic callers | `narrow-signature` |  |
| open work | `concrete-annotation` | F13 Result annotation converts instead of checking<br>F15 Concrete annotation blocks generic callers | `narrow-signature`, `result-conversion` |  |
| open work | `enumerated-union` | F20 Ad-hoc union of unrelated types where sum type belongs | `vague-type` |  |
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
<!-- /coverage -->
