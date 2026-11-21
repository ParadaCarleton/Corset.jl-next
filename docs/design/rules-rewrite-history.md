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
| 1 | `infer_effects` gives no per-argument writes | Fixed: own bottom-up write summary (`!` convention). Unknown callee gives `possible`. |
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

## Early design review: adversarial pass

| # | Finding | Outcome |
|---|---|---|
| 1 | Syntax-only F36 can be false `definite` (`CircularDeque`) | Fixed: syntax-only F36 is `possible`. |
| 2 | Error-path exemption hides write before caught throw | Fixed: only fresh local objects exempt; argument and global writes stay. |
| 3 | 5× target compares different scopes; effects too slow | Fixed: remeasure legacy in same scope; effects phase gets own budget. |
| 4 | Argus candidate-node speed unmeasured | Fixed: benchmark first in phase 2. |
| 5 | Range exemption rests on open question | Fixtures added. Rejected "keep possible": exemption covers only uses proven index-only; rest reports as before. |
| 6 | Family B on L1 and L2 | Fixed: B on L1 only. |
| 7 | Soft-scope predeclaration missing | Fixed: Scope contract declares globals in include order. |
| 8 | "Every package method" overstates coverage | Fixed: eligible methods; coverage line counts rest. |
| 9 | F1 needs whitespace; Argus ignores trivia | Fixed: F1 reads source bytes. |
| 10 | LintApp check source stale | Fixed: JuliaWorkspaces named. |

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

Reread `types.md`, `pipeline.md`, `stages.toml` before phase 4.
- Stand-in function returns `Any`: inference barrier keeps later code analyzed.
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
- Curly callee (`Vector{Float64}(n)`) once went unmatched: lowering builds callee with `Core.apply_type`, so no span spelled it. Finding names callee as source spells it, not bare `Array`.
- Corpus: DataStructures 1 `definite` (`empty` of `DefaultDictBase`) and 1 `possible` (`SortedSet{K,Ord}()` default ordering fails `Ord`); both reproduce. Distances 12 `possible`, from `Any` elements. JSON none.
- Coverage line listed 930 DataStructures blind spots. Text report now lists three per cause; JSON and SARIF list each one.
- Method store keeps stage facts per method and signature; rules run each time. Design planned file hashes of reached methods as dependencies.
- File hashes missed macro output: expansion lands in caller's file and leaves no compiler edge. Entry now records lowered code of each method inference read.
- Lowered code also covers `@eval` code and closure names: closure that edit renumbers has other code. Edit of one method invalidates only entries that read it.
- Generated code depends on generator and its callees, so entry records generated code per instance; run calls generator again to check it.
- `@enum` value made serializer throw in package shape. Shape serializes only plain constants: numbers, strings, symbols and immutable structs of those.
- Shape serialized tuple per struct layout and compiled serializer once per tuple type: 1.9 s on DataStructures. `Vector{Any}` and field loop fix it.
- SparseArrays.jl `_cat` invalidated `line_starts` (`vcat` of number and vector) and every caller: package and inference stages recompiled after trigger load. Loop fixes it.
- ChainRulesCore.jl `promote_rule` invalidated 99 Corset instances: first `check` of inference fixture took 2.9 s, against 0.68 s.
- Corset half: signature parameters inferred `Any` (`tuple_parameters` fixes it); `location_span` took `AbstractString`; `path_parts` built `Vector{Any}`. Barriers guard calls into Argus.jl, TypedSyntax.jl, Aqua.jl and Pkg. Run: 2.2 s.
- Other half sits in dependencies: Argus.jl `_infix_ops` calls `Kind(::Any)`; TypedSyntax.jl calls `source_line(::Any)`. Their re-inference costs 0.86 s and 0.72 s. One type assertion in each brings run to 0.7 s.

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

### Phase 4 type disruption

- `Widening` engine converts weak values in copy of lowered code and runs native inference on copy (`InferenceState` from edited `CodeInfo`). No custom interpreter.
- First draft converted one weak value at a time. `x * 2.0 + 1.0` then found only `2.0`: `1.0` meets input only once `2.0` converts. Engine now converts all, repeats rounds until no new meeting, then leaves each weak value out alone. Nested polynomial needs one round per level.
- Type names count only as callee, `convert` target and broadcast function. As argument (`zeros(Float64, n)`), name is hard-coded array type: F16.
- Julia 1.13 lowering reads globals and variables into own statements (`%3 = Main.HALF`); engine resolves reads. It turns `global g = v` into `setglobal!` behind `isa` test of declared type; that test is no type branch.
- Inference wraps unreached statements in `Core.Const`. Only reached `Union{}` statements count as throwing.
- TypedSyntax.jl maps broadcast to `materialize` statement only. `statement_nodes` gives each `broadcasted` statement dotcall node of its consumer. Product `2x` parses as `juxtapose`; `spells` accepts it for `*`.
- Corpus run, integer input: DataStructures gave 22 findings, all index math (`heapleft(i) = 2i`, page ids) or `UInt64(n)` bit masks; JSON gave 3 in digit loop. Julia promotes small integers to `Int` on purpose (`sum(Int32[1])`), and design already called `heapleft` fine. Rules now take float input only; index-only analysis served integer input alone and went.
- Corpus also found: conversion to narrower or other-kind type counted as widening; dictionary store ignored value type; weak value dropped for breaking call met input again each round. Each has regression test.
- First meeting test asked whether result follows input. `x => 0.5` and struct with own parameter per field passed it, though they promote nothing. Meeting now needs input to absorb weak value: with input at `Float64`, conversion changes nothing. Lazy broadcast compares array it materializes to.
- Mutation check of `Widening`: 27 of 33 mutants killed at first. Three checks were redundant and went (`isa` branch case, name kind, type-name variable); two gaps got tests (tuple builtin, intermediate behind tuple). `Bool` and builtin skips change no finding; they save meeting tests.
- Corpus cost, uncached, branch against main: DataStructures 85 s against 82 s, Distances 20 s against 21 s, JSON 87 s against 86 s. Distances writes no float literal in generic code and gave no finding.
- Float corpus evidence stays thin. irv-extremism crashed on main before inference (DynamicPPL `@model` evaluator; struct bound rejecting array stand-in; fixed in #217). After that fix, inference with stand-ins runs Enzyme `@generated` thunk generator, which aborts process in LLVM. Inference now runs in supervised child process; crash journal skips method whose inference aborts (#220).
- `lost-narrowing` (F107) came from Corset code: `(x isa T && …) || return` left `x` untyped in Julia 1.13. Lowering branches directly on `||` chain, ternary and `if a && b`; only value of `&&` chain, or condition stored in variable, drops narrowing. Self-lint found 8 more sites in Corset; fixer split 6.
- F16 narrowed from "report hard-coded `Array` everywhere": footgun needs caller's array, so method without input array gets no finding. `breaking` fix that adds array type parameter went with it.
- `HardArrays` reuses `Widening` conversion: callee `zeros` becomes `Templated{ArrayStandIn}(zeros)`, so no statement renumbering. Stand-in broadcast style wins over `Array`, so `xs .+ zeros(n)` keeps stand-in type; meeting test catches such mixing instead.
- Array meeting must read array types of original code: in partly converted copy, other constructions hold stand-in arrays too, and two hard-coded arrays would meet each other.
- Annotation guesses first read only `reached` signatures. `reached` follows stand-in calls alone, so concrete callers (`total_area(::Float64, ::Int)`) gave no evidence. Guesses now read every package call site of inferred code, with result type there.
- `RuleEntry.fix_stage` names stage for fixes. Without it, `annotation` fix would depend on other enabled `inference` rules: hidden input.
- `Narrowing` reads per-block variable types inference keeps (`bb_vartables`), so loss check needs no second inference. Lowering reads `x === nothing` again on its own true branch, where narrowed type is `Union{}`; scan treats that outcome as one that never happens.

### Phase 4 code review: adversarial pass

Codex reviewed phase 4 code (`a0a64e4` to annotation guesses) by trace only. Each fixed finding has regression test.

| # | Finding | Outcome |
|---|---|---|
| 1 | Result guess `likely` when stand-ins miss type branch (`x isa BigFloat ? "big" : 1`) | Fixed: `likely` needs own inference over every declared type: concrete, real or real array argument, no keyword, no skipped signature, no type test. |
| 2 | `fix` checks edited files in process that loaded package before edits | Fixed: relaunched `fix` exits `3`; relaunching process runs `check` in fresh process, with new crash journal. |
| 3 | Store into returned local container (`out = Any[]; push!(out, v); out`) counts as intermediate | Fixed: store into local that method returns counts as exit. |
| 4 | Analysis with crash blind spot enters analysis cache, so crash never retries | Kept: native abort repeats, and retry costs crash per run. Coverage line shows blind spot; `--no-cache` retries. |
| 5 | `oftype(x, 1e39)` gives `Inf32`, but fix is `likely` | Fixed: literal outside `Float32` range gives `manual` fix. |
| 6 | Crash key survives edit of method body | Fixed by 2: post-fix check runs with new journal. Journal lives for one supervised run. |
| 7 | Torn last journal record makes relaunch throw | Fixed: record is length, then bytes, in one write; short last record drops. |

- Corpus run of fixes found false positive in computed result type (`::promote_type(T, S, Float32)`). Lowering keeps returned `-Inf32` in unnamed slot, and converted code infers `Any`. Unnamed slot now takes kind of its value. Widening needs computing call with number type on both sides. Exit needs known converted type.
- Abstract result type (`f(x)::Real`) and typed local (`y::Real = v`) lower to `isa` test with conversion. `type_branch` counted it, so every such finding dropped to `possible`. Lowering assigns `typeassert(convert(T, v), T)` back to tested slot; source `isa` never does.

### Phase 5 design

Reread `effects.md`, `stages.toml` before phase 5. Superseded by **Phase 5 redesign**.
- Legacy Corset and julia-anal Method B reached low unknown share by name trust: `!` callee writes first argument, other callee writes nothing. julia-anal Branch 3 retracted that policy. Sound Branch 3 left 74.4% of Base methods undecided.
- Name trust is rejected: `!` does not tell which argument changes.
- Base interface functions (`getindex`, `iterate`, arithmetic, `==`, `length`, `convert`, `getproperty`, `setindex!`) dominate open calls. Contract table closes them; breach at implementing method is finding.
- Callback writes belong to callback: summary keeps call of parameter symbolic until caller supplies callee (julia-anal Branch 3 sees through `_apply_iterate` too).
- Unknown call ties result to operands in one direction.
- IR: pre-inline, shared with `inference` stage, so allocation and consumer calls map through phase 4 source map. Risk: more instances than optimized IR; measure in engine PR.

### Phase 5 design: adversarial pass

Codex review of phase 5 design found seven problems:

| # | Finding | Outcome |
|---|---|---|
| 1 | Base contract hides real writes (`DefaultDict` `getindex` inserts, `Stateful` `iterate`) and omits result aliases (`view`, `convert`) | Accepted: contract entries list reads, writes and result alias. Known argument types use real summaries; breach is finding in target package only. |
| 2 | Join over loaded methods misses methods later packages add | Accepted: contract and join verdicts keep write certainty; their "writes nothing" is at most `possible`. |
| 3 | Callback writes must reach enclosing method (`foreach(x -> push!(sink, x), xs)`, `Fix1`) | Accepted: combinator writes nothing; caller with known callee substitutes summary and captured aliases. Fixtures for closure, `Fix1`, callable struct. |
| 4 | Flow-insensitive classes cannot order reads and writes per allocation | Accepted: lifecycle keeps allocation identity, must-alias facts and statement events; branch join is `possible`. |
| 5 | `possible` share rewards unsound shortcuts; denominator undefined | Accepted: denominator fixed, hand audit of contract and join verdicts, threshold in phase 5 exit row. |
| 6 | Pre-inline IR and full joins lack cost data | Accepted: engine PR measures instances, foreign calls, memory, cold and warm time; join over more than 64 methods is unknown. |
| 7 | Summary drops writes before caught throw | Accepted: definite writes on throwing paths stay; unknown calls there add nothing; throw-only exemption needs no write on any path. |

- Phase 4 history names `typeinf_ircode` at `"CC: COMPACT_1"`; `inference` stage uses unoptimized typed code from `typeinf_frame`. Effects engine builds SSA IR before inlining on same inference.

### Equality contract

- `operator-consistency` follows Base `isequal` and `hash` docs. Earlier fix text ("define `hash` from fields `==` compares") left signed zeros broken: `isequal` falls back to `==`, which calls `0.0` and `-0.0` equal, and their hashes differ.
- New kinds: `hash` reads field equality ignores; float fields without `isequal`; `hash` without equality; 1-argument `hash`; `isless` against equality fields.
- Field sets come from lowered code (`x.field`, `getfield(x, :field)`); any other use of argument leaves set unknown and skips field checks.
- Corpus case: QuadGK `Segment` (`==` without `hash`, `isless` by error only); upstream issue JuliaMath/QuadGK.jl#145.

### Phase 5 redesign

Engine starts new (`effects.md`, Effects engine). Decisions and reasons:

- Units: `inference` stage units only, as `types.md` sets signatures. Declared signatures assume open world.
- IR: SSA IR from unit's own typed code; package code needs no second inference.
- Points-to: inclusion-based and field-sensitive. Unification merges unrelated objects at each unknown call.
- Provenance: opaque, opt-out, code. Doubt test needs to know where open type comes from.
- Explicit `::Any` is opt-out (`types.md`); `findings.md` example now names untyped argument. Earlier text let `::Any` both give and hide findings.
- Compiler effects: used for speed. `effect_free` true is proof; empty summary also needs `inaccessiblememonly` and result without reference, since `view` result aliases argument.
- Cuts: call or store live at declared signature and dead at stand-in. Failing calls and type tests both hide writes (`x isa BigFloat && (STATE[] += 1)`).
- Effect kinds: summary keeps kinds; rules apply exemptions from audited Base table. Default RNG read is hidden input; `lock(lk)` is not unused call.
- Library cache key holds content digest per loaded package: path dependency edit changes no Manifest entry.
- Allocation in loop or recursion gives may-alias only. Element events carry index; call facts record result use (F86).
- Contracts stay for open dispatch: rules assume Base contracts (`findings.md`).
- Solver cost and accuracy are unmeasured; engine PR measures them before rule PRs.
- PR order: `phase5.md`.

### Phase 5 redesign: adversarial pass

Codex review of redesign saw design parts and `src/` only. Eight problems:

| # | Finding | Outcome |
|---|---|---|
| 1 | Opt-out provenance hides direct write to `::Any` argument (`setfield!(x, :n, 0)`) | Accepted: provenance judges open dispatch only; code, resolved, joined and contract writes keep certainty. |
| 2 | Open call can return global that no operand names; write through it is lost | Accepted: origin `unknown`; write to it is `possible` global write. |
| 3 | Dropped unknown calls on throwing paths hide `foreign_mutate!(x); error()`; `unused-call` can delete call that throws | Accepted: only message-building calls add nothing; call facts carry may-throw; `unused-call` needs no throw. |
| 4 | Signatures over limit leave writes unseen, yet verdict can be none | Accepted: incomplete method gets no definite none. |
| 5 | False `@assume_effects` in dependency makes shortcut unsound | Accepted: shortcut needs no effects override outside Base on reached methods; own analysis runs on claimed methods. |
| 6 | `iterate` read-only contract hides `Iterators.Stateful` writes | Accepted: contracts hold documented behavior only; Base breaker gives `possible` write. |
| 7 | `inference` stage drops typed code; effects has no IR | Accepted: stage hands typed units of this run to effects; store keeps summaries. |
| 8 | Warm-only gate passes while cold run misses speed budget | Accepted: go/no-go adds cold full run inside budget and measures empty library cache. |

### Enums and sum types

- Branch over cases: extensible cases use dispatch on subtypes; fixed cases use sum types, so checks find unhandled cases. Base `@enum` gives neither, so `unchecked-enum` (F108) reports it.
- Rule waits for Moshi release with exhaustiveness check: without it, Moshi finds missing arm only at run time, as `@enum` does.
- Ordered enum needs order in Moshi. Order chain (`Safe() < Likely()`) defines `isless` alone; `@derive Ord` beside it would give two ways to say one thing.
- Chain names every variant: `sort` assumes total order. Singletons only in first version. Mixed `<` and `>` is error. Ordered type is immutable, so `===` agrees with `isless`.
- Enum with explicit values or base type is exempt: C interop, bit flags and wire formats need stable integers.
- Corset enums move from EnumX to Moshi in `unchecked-enum` PR. Ordering serves fix tiers (`fix.tier > allowed`) and stages (`fix_stage >= stage`).

### Safety group

- `correctness` split in two. `correctness` keeps code that misbehaves now and stays `deny`. `safety` is `warn`, as Clippy `suspicious` is beside `correctness`.
- `safety`: code works now, but later mistake passes silently. Fix makes Julia catch it: error, exhaustiveness check or failed test.
- Moved from `correctness`: `broad-catch` (F59), `orphan-task` (F70), `result-conversion` (F13), `untested-extension` (F88).
- Moved from `readability`: `ad-hoc-union` (F20), `unchecked-enum` (F108). Readability holds house style; missed case is no style problem.
- Every project kind enables `safety`: scripts had these rules at `deny` before.
- Stays in `correctness`: `hidden-input` and `impure-lambda` (fix adds no check), `unguarded-release` (throw path misbehaves now).
- `unverified-inbounds` (F37) stays in `correctness`: out-of-bounds access under `@inbounds` is undefined behavior, so `deny` fits.

### Phase 5 engine core

PR 1 measurements on corpus, cold library inference, no summary cache (`phase5.md`, PR 1):

| Package | Units | Instances | `inference` s | `effects` s | Allocated GB | Peak RSS GB | Methods | `possible` write | Definite write | Blind write |
|---|---|---|---|---|---|---|---|---|---|---|
| Distances 0.10.12 | 549 | 4691 | 3.2 | 5.8 | 1.2 | 0.9 | 175 | 54% | 27 | 35 |
| DataStructures 0.18.22 | 1593 | 7065 | 4.1 | 7.9 | 1.8 | 1.2 | 943 | 56% | 168 | 249 |
| JSON 1.13.4 | 385 | 7333 | 5.8 | 24.2 | 7.2 | 1.1 | 291 | 58% | 61 | 78 |

- `possible` share sits near 55%: every call outside builtins and one-method dispatch stays open until PR 2. Gate threshold is 30%.
- `effects` takes 1.8 to 4.1 times `inference` time. Library summary cache (PR 4) carries budget.
- JSON time comes from Serialization in cycle with `deserialize`: callee summaries with hundreds of stores. Mapping each callee place once per call statement and round cut it from 148 s to 24 s.
- Corpus found two IR shapes engine rejected: `cglobal((:name, library))` keeps tuple as nested expression; `splatnew` on tuple without definite field count.
- `@match` expands to `@goto`, so closures in same function box captures. Boxed `Any` result let target `AbstractSet` method invalidate engine code. `test/boxes.jl` now rejects `Core.Box` in every Corset method.
- Graphs.jl added 0.35 s to Corset load and 12 packages. Own iterative Tarjan replaced it (#233): `using Corset` 1.4 s to 1.1 s.

### Phase 5 call resolution

Open calls after PR 1, by kind: foreign call, join of 2 to 8 methods, dispatch over 8 methods, zero match, callee value.
Ablation on corpus: one kind stays open; every other open call writes nothing. Cell: methods with `possible` write.

| Kind left open | Distances | DataStructures | JSON |
|---|---|---|---|
| Foreign call | 25% | 15% | 34% |
| Join of 2 to 8 | 35% | 33% | 39% |
| Dispatch over 8 | 34% | 23% | 31% |
| Zero match | 4% | 8% | 13% |
| Callee value | 9% | 7% | 15% |
| None | 3% | 0% | 13% |

- Foreign table, join and contracts are each necessary for 30% gate.
- Dispatch over 8 is mostly Base interface functions: `==` (11 methods) in 1971 JSON calls, `convert` in 269 DataStructures calls. Contracts cover these.
- Zero-match call throws `MethodError`, so it becomes dead code, as in inference.
- PR 2 lands as stacked PRs: 2a foreign table, zero match, join; 2b Base contracts; 2c callback records, provenance.
- Path depth sweep: depth 3 and 4 kept `possible` share. JSON `effects` took 19 s at depth 2, 615 s at 3, over 3 h at 4. Depth stays 2.
- `foreach(f, xs)` reaches closure through `foldl` wrappers, so its write path has depth 3. Callback records keep path short.

PR 2a on corpus, cold library inference, no cache. Cell: `possible` write share, `effects` seconds.

| Join scope | Distances | DataStructures | JSON |
|---|---|---|---|
| PR 1 | 54.3%, 5.8 | 55.6%, 7.9 | 58.1%, 24.2 |
| None | 52.0%, 4.0 | 49.0%, 4.8 | 47.8%, 21.4 |
| Package code, limit 3 (shipped) | 51.4%, 3.7 | 47.5%, 5.9 | 47.4%, 178 |
| All code, limit 3 | 53.7%, 5.6 | 48.7%, 18.0 | over 1800 |

- Foreign table and zero match cut `possible` share by 2 to 10 points. Joins add at most 1.5 points before contracts and callback records.
- Limit 8 in all code reached 91,670 instances on Distances, against 4,691 in PR 1 and 8,165 at limit 3.
- Joins in library code raised `possible` share: joined callees show global writes that open calls leave out.
- JSON with package joins took 178 s and allocated 66 GB. Library summaries with over 1000 stores (`show`) repeat each round in call cycles.
- PR 3 limits and PR 4 cache target JSON time. Gate needs `effects` at most `inference` time (5.8 s).
- First corpus run hung: LinearAlgebra `_any(f ∘ transpose, parent(A), :)` adds `ComposedFunction` layer per step. Recursion limit ports `abstract_call_method` rule.
- Crash journal key printed type with alias search: up to seconds per deep type. Non-compact `show` skips search.
- Join is not monotone: summaries in call cycle oscillated for 9 h. Widening after 8 reruns ends it; corpus shows no unsettled access.
- PR 1 and PR 2a tables ran on laptop low on memory. Later timings run on winwsl; compare arms of one run only.

PR 2b on corpus, winwsl, cold library inference, no cache, PR 2a and PR 2b back to back (`benchmark/effects.jl`):

| Arm | Distances | DataStructures | JSON |
|---|---|---|---|
| PR 2a: `possible` share, `effects` s | 51.8%, 10.7 | 47.5%, 14.7 | 47.4%, 348 |
| PR 2b: `possible` share, `effects` s | 34.9%, 8.2 | 32.7%, 14.6 | 36.8%, 625 |
| Open calls, PR 2a to PR 2b | 1232 to 295 | 2093 to 563 | 6335 to 1266 |
| Contract calls | 937 | 1530 | 5069 |

- Contracts cut `possible` share by 11 to 17 points. Blind writes fall too: 36 to 20 on Distances, 264 to 193 on DataStructures.
- JSON `effects` takes 1.8 times PR 2a time and allocates 95 GB, against 65 GB. Resolved calls add stores to Serialization summaries.
- First table aliased every query result: JSON ran over 1800 s and ran out of memory. Ablation of contract parts on JSON:

| Contract part removed | `effects` s | `possible` share |
|---|---|---|
| None | 1128 | 36.8% |
| Result aliases | 378 | 36.8% |
| Element results | 745 | 36.8% |
| Stores and copies | 696 | 36.8% |

- Query results (comparison, size, arithmetic) hold no reference or hold new value, so plain queries alias nothing. Alias queries are explicit list.

Open-call census after PR 2b: each `possible` write of package method traced through callee summaries to open call that starts it.
Cell: methods with `possible` write from that kind; in parentheses, methods with that kind as only source.

| Kind | Distances | DataStructures | JSON |
|---|---|---|---|
| Callee is parameter or field | 0 | 20 (9) | 18 (2) |
| Callee is computed value | 9 (0) | 115 (58) | 7 (3) |
| Splat of unknown length | 9 (0) | 115 (69) | 55 (2) |
| Dispatch over limit, package code | 39 (26) | 36 (8) | 67 (9) |
| Dispatch in library code | 25 (2) | 129 (26) | 87 (25) |
| Unknown foreign call | 23 (0) | 21 (0) | 13 (3) |
| Contract breach | 9 (0) | 44 (6) | 56 (2) |

- Callback records reach fewest methods, so they move to last PR. Splat dispatch comes first.
- Computed callee in DataStructures: `convert(::Type{T}, ::AbstractDict)` calls `T(x)` with abstract `T`.
- Distances package dispatch: `_evaluate` on untyped arguments has more than 3 methods.
- Distances: 17 methods also reach callee taken from spread tuple; no method has it as only source.
- Census found function stand-in bug: stand-in call was `effect_free`, so compaction deleted it. Method calling `f::Function` got "writes nothing" (#236).

PR 2c (splat dispatch, #237) on corpus, winwsl, cold library inference, no cache, main and PR 2c back to back:

| Arm | Distances | DataStructures | JSON |
|---|---|---|---|
| Main: `possible` share, `effects` s | 34.9%, 8.6 | 32.7%, 7.8 | 36.8%, 430 |
| PR 2c: `possible` share, `effects` s | 34.9%, 6.6 | 28.8%, 11.0 | 36.1%, 546 |
| Open calls, main to PR 2c | 295 to 295 | 567 to 499 | 1269 to 1257 |
| Instances, main to PR 2c | 4079 to 4079 | 8085 to 8771 | 9050 to 9052 |

- Splat dispatch cut DataStructures `possible` share by 3.9 points and JSON by 0.7. Distances splats nothing it can resolve.
- DataStructures blind writes rose from 193 to 243: splat of tuple with unknown length collapses caller tuple to `deep`.
- `effects` time on DataStructures and JSON rose with instances that splat dispatch reaches.

PR 2d (provenance, #238) on corpus, winwsl, cold library inference, no cache; 2c and PR 2d in separate box jobs:

| Arm | Distances | DataStructures | JSON |
|---|---|---|---|
| 2c: `possible` share, blind writes | 34.9%, 20 | 28.8%, 243 | 36.1%, 89 |
| PR 2d: `possible` share, blind writes | 34.9%, 20 | 26.7%, 251 | 33.3%, 94 |
| Open calls, 2c to PR 2d (`Open` + `Unresolved`) | 295 to 248 + 47 | 499 to 459 + 45 | 1257 to 1097 + 161 |
| `open dispatch on opaque data` spots | 5 | 51 | 11 |
| `effects` allocation MB, 2c to PR 2d | 800 to 821 | 1736 to 1762 | 94074 to 102645 |

- Provenance cut DataStructures `possible` share by 2.1 points and JSON by 2.8. Definite writes stay the same.
- First 2d commit kept `Doubt` as 16-byte struct: JSON allocation rose 80%. Solve reruns and rounds stayed the same (11376 to 11388 summaries); every engine frame grew by about a quarter.
- Each `Targets` entry holds one `Doubt`. Packed 4-byte `Doubt` brings JSON allocation to 9% over 2c; 8-byte layout gave 34%.
- Mutation check found caller remap untested: every fixture passed callee arguments in same positions. Tests now swap positions.

PR 2e (callback records, #239) on corpus, winwsl, cold library inference, no cache, main and PR 2e back to back:

| Arm | Distances | DataStructures | JSON |
|---|---|---|---|
| `possible` share, both arms | 34.9% | 26.7% | 33.3% |
| Definite writes, main to PR 2e | 27 to 27 | 193 to 198 | 63 to 63 |
| Blind writes, main to PR 2e | 20 to 20 | 251 to 246 | 94 to 94 |
| `effects` allocation MB, main to PR 2e | 822 to 823 | 1761 to 1772 | 105981 to 112717 |

- Records turn 5 DataStructures blind writes definite. Call counts and variants stay the same.
- Probe of 20 callback shapes: tuple `foreach`, `Base.Fix1`, `ntuple` and `sort!(; by)` closures lose blind `deep` writes.
- Generator into `sum` stays blind: `_xfadjoint` returns tuple holding `MappingRF`, and caller merges 2 fresh callee nodes into one.
- Closure in `Function` field stays `possible`: abstract callable type reaches no method.
- Resolved-record set made per `apply!` raised JSON allocation 7%. Set made on first record takes 0.6 points off.
- `effects` allocation counts cold native inference. Parallel arms of main gave 102059 and 158294 MB with same verdicts: compare serial arms only.
- Mutation check: 12 mutants, 10 killed. Survivors kept record of round 1 after callable grew, and resolved record of cycle member without reading its summary.
- Fixtures `pick_setter!` and `restart!` kill both survivors.

### Phase 5 engine limits

Probe before PR 3a: compiler effects make 41%, 20% and 32% of variants on Distances, DataStructures and JSON eligible for shortcut.
Eligible variants hold 24%, 9.4% and 9.7% of IR statements. Their own summaries were mostly immutable reads and false-positive writes.

PR 3a (compiler-effects shortcut, #240) on corpus, winwsl, cold library inference, no cache, main and PR 3a back to back:

| Arm | Distances | DataStructures | JSON |
|---|---|---|---|
| Shortcut instances, PR 3a | 789 | 1127 | 1637 |
| Instances, main to PR 3a | 4079 to 3002 | 8762 to 7923 | 9045 to 7521 |
| `possible` share, main to PR 3a | 34.9% to 34.9% | 26.7% to 26.6% | 33.3% to 33.3% |
| Blind writes, main to PR 3a | 20 to 27 | 246 to 240 | 94 to 94 |
| `effects` allocation MB, main to PR 3a | 823 to 608 | 1772 to 1645 | 114293 to 113097 |
| Warm solve allocation MB, main to PR 3a | 403 to 326 | 1202 to 1159 | 113272 to 112172 |

- Warm solve allocation counts engine only; `effects` allocation also counts cold native inference.
- Distances blind writes rise: shortcut removes false code-level write of `promote_op` to unknown object. That write hid blind write to same place, since `stronger` keeps least doubt.
- Distances has 9 shortcut instances with nonempty own summary. Compiler disproves each: `promote_op` writes, throw-only `LazyString` message, uninhabited `SubArray{T, 1, Union{}}`, read-only callback records.
- JSON allocation stays within 1%: its cost sits in Serialization call cycles (PR 1).
- Corset, Moshi and Compiler carry claims (`@assume_effects`, generated methods), so no run can skip reach check of claims.
- Coverage instrumentation (`--code-coverage=user`) gives every fixture statement an effect. Shortcut tests use Base instances.
- Mutation check: 16 mutants over shortcut conditions, claims, reach and compaction keep; all killed.

PR 3b (stand-in cuts, #241) on corpus, winwsl, main and PR 3b back to back:

| Arm | Distances | DataStructures | JSON |
|---|---|---|---|
| Incomplete methods, main to PR 3b | 32 to 37 | 113 to 130 | 39 to 47 |
| Cut units / units | 144 / 509 | 28 / 1593 | 22 / 385 |
| Library cut instances | 0 | 0 | 0 |
| `stand-in cuts path` spots | 3 | 3 | 0 |
| Warm solve allocation MB, main to PR 3b | 330 to 367 | 1162 to 1200 | 111765 to 112647 |

- First cut kept shortcut on callers: compiler proves caller of cut unit empty. Compaction also deleted effect-free calls to cut units. Both now treat cut instance like claim.
- Caught failure leaves instance `nothrow`, so method with `try` still gets library cut check.
- Codex review found three hidden writes: package call that dispatches to other method on stand-in, type branch outside Base, generated code whose statements differ per signature.
- Distances cuts are mostly dead loop bodies. Untyped `AbstractVector` stand-in is `ArrayStandIn{Any, 1}`; `oneunit(eltype(a))` fails on `Any`, so `colwise!` loop body `r[rj] = metric(...)` is dead.
- Return conversions cause no cuts: 0, 7 and 0 units whose cuts are only `convert` or `typeassert`.
- `possible` share and blind writes do not change: cut methods carry other writes, so spot condition (no write) holds rarely.

### Open array stand-ins

- Cut probe of PR 3b: 144 of 509 Distances units carried cut, mostly dead loop bodies.
- Cause: untyped `AbstractVector` took `ArrayStandIn{Any, 1}`. `oneunit(eltype(a))` is `oneunit(Any)`, which fails on stand-in and model, so code after it is dead.
- Concrete `Any` element is one arbitrary element type. Open element (`ArrayStandIn{<:Any, 1}`) states what annotation states: any element.
- Old rule also fixed dimensions at first fit from 1 to 3: `AbstractArray` gave vector only, 4-dimension argument got no stand-in.
- Open `<:Real` element was rejected: inference gives `xs .* 0.5` abstract type, so `type-disruption` loses float widening. Number stand-ins stay.
- Open stand-in breaks concrete-signature rule of worklist. Family test sets each variable to its bound; view of open stand-in holds it as variable bound.
- Engine reads fields of array stand-in and `Array` families from their body (`Array{T, 1} where T`), so writes through open stand-in keep paths.
- Field names for every struct family were rejected: JSON solve took 1459 s against 462 s on 3b. Named paths through code families (`WriteClosure{JS, arraylike, I} where …`) multiply places at each call. Stand-in and `Array` families alone took 488 s in parallel arms.
- `Array` family in `layout` costs JSON 145 GB effects allocation against 112 GB without it; no JSON verdict changes.
- Without family, writes through generic `Vector{K}` fields gain `:ref` step: DataStructures loses 2 definite writes and gains 33 alias spots.
- Family for memory backing alone still took 141 GB, so whole family stays.
- Distances `possible` share rose from 34.9% to 44.7%: open calls on values derived from open element (`promote_type(eltype(r), …)`) had no opaque source. Type values and fresh arrays carry no object origin. Rule: call result with open type takes sources of its open operands.

### Derived provenance

- First version joined derived sources with object sources: DataStructures `possible` share rose from 26.7% to 27.6%. Fresh objects added `INHERENT` beside opaque derived source.
- Objects now decide when they give a source. Static parameters and arguments give theirs: Distances 44.7% to 42.6%.
- Join of methods gave doubt in code to access that some members lack. Operand types pick member, so dispatch doubt replaces it: Distances 31.9%, DataStructures 23.7%.
- Consumed-iterator breach gave doubt in code: `first(LinearIndices(dest))` inside `copyto!` reached `_pairwise!`. Breached argument type decides breach, so its sources replace it: Distances 30.9%.
- JSON `possible` share fell from 32.6% to 29.9%; effects allocation rose 1%.
- Early fixpoint rounds see sources still unknown. Accesses come from last round only, so their `INHERENT` stays out.

### Throw paths

- Message call builds thrown value only: `string(x)` in `throw(ArgumentError(string(x)))`. Its writes counted as writes of method.
- Rejected: drop all writes of message call. Message can pop argument (`pop!(stack)` in error text); caller that catches sees it.
- Chosen: message call adds definite writes only. Its `possible` writes and blind spots stay out.
- Sink: `throw` or throw helper call of type `Union{}`. Other call that never returns fails on stand-in; stand-in cuts handle it.
- Statement without use is no message: `all` over no uses holds, so `x[i] = v` result would drop its write.
- Least fixpoint runs reverse passes. Phi at loop header uses statement later in body, so it needs second pass.

Main and throw paths back to back on macdev:

| Arm | Distances | DataStructures | JSON |
|---|---|---|---|
| `possible` share | 30.9% to 30.9% | 23.7% to 23.7% | 29.9% to 29.2% |
| Blind writes | 65 to 64 | 277 to 272 | 96 to 93 |
| `effects` allocation MB | 976 to 998 | 1781 to 1811 | 144693 to 145435 |
| Warm solve allocation MB | 498 to 502 | 1285 to 1300 | 143748 to 144437 |

- Blind writes count methods. Distances and DataStructures verdicts lose blind `alias` places only.
- Distances loses 23 places in `_evaluate`, 1 in `RenyiDivergence`. DataStructures loses 14 in `fenwick`, `trie`, `avl_tree`, `RobinDict`.
- JSON `liftkey` loses `possible` writes to string argument: `parse` error text calls `repr(x)`. `unknownmember` error text shows key.
- `liftkey` write becomes blind (opaque dispatch): message write had hidden it, since `stronger` keeps least doubt.
- JSON `_makecontainer` and `make` lose 18 blind places each: MPFR precision globals in `BigFloat` error text.
- 3a shortcut already removed most message writes: compiler proves `LazyString` message effect-free.
- Mutation: 15 mutants. First run killed 4; 6 survived; 5 timed out with control. Tests cover each survivor; recheck skipped.

### Call facts

- F54 needs discarded calls. `COMPACT_1` deletes discarded call when compiler effects say removable: exactly F54 candidates.
- Chosen: unit keeps every call statement. Library instances keep compaction.
- Unit with shortcut keeps code for call facts. Its summary stays empty, so shortcut precision stays.
- Root rerun with record flag sends writes of each call through scratch table. Other instances pay nothing.
- Callee lock or file held at exit counts as effect: discarded `hold!(q)` is no unused call.
- Units of method merge by source statement and span: lowered statement index is same in every unit.
- Corpus arm 605 (ssh-dev, loaded): verdicts and blind spots equal release-balance arm 578 on Distances, DataStructures, JSON.
- Calls, discarded, F54 candidates: Distances 1874, 414, 335; DataStructures 6699, 1403, 642; JSON 2648, 668, 511.
- Effects allocation: Distances +14%, DataStructures +11%, JSON flat. Kept calls add statements to units.
- Bug: `used` came from IR after `COMPACT_1`. Compaction turns each use of constant result into literal.
- So `b == UInt8('\t')` gave unused call; most F54 candidates were constant calls. Fix #252: count uses before compaction.
- After #252 (job 623): discarded and F54 candidates Distances 112, 34; DataStructures 793, 85; JSON 202, 62.
- Job 626: three Distances and two DataStructures processes give same facts. Blind-spot change between arms comes from code.

### Iteration starts

- Row 3 listed iteration starts; split 3a to 3e left it out. Found while closing row 3.
- Start is read of kind `iteration`: callee mapping, join, widening and callback records reuse read paths.
- Rejected: own start table. Every apply and join signature would carry third table.
- `iterate(x)` starts at every resolution. `iterate` method with one argument continues with state, so its summary shows no start.
- `first`, `only`, `isempty` and destructuring start through contract only. Static call shows start through callee summary.
- Own method of type starts nothing: `isempty(::Vector)` reads length.
- Splat of collection runs `iterate` too. It stays unresolved and gives no start yet.

### Numerics survey

- Corpus had one numeric package (Distances). Survey ran 12 numeric packages on main 65d54fbb, empty cache (jobs 659, 660).

| Package | `inference` s | `effects` s | Warm solve s | `possible` | Blind write |
|---|---|---|---|---|---|
| SpecialFunctions 2.9.2 | 15.1 | 16.5 | 3.5 | 18.0% | 15% |
| StatsFuns 2.3.1 | 7.3 | 11.2 | 1.8 | 20.1% | 20% |
| QuadGK 2.11.3 | 5.8 | 13.6 | 3.4 | 57.6% | 32% |
| Roots 3.0.14 | 3.4 | 13.8 | 2.9 | 10.1% | 10% |
| Polynomials 4.1.6 | 21.7 | 69.7 | 38.0 | 52.3% | 50% |
| ForwardDiff 1.5.0 | 7.9 | 17.6 | 5.3 | 26.7% | 84% |
| StaticArrays 1.9.25 | 13.6 | 24.6 | 4.6 | 29.7% | 35% |
| Optim 2.3.2 | 26.3 | 80.2 | 18.1 | 15.8% | 21% |
| Distributions 0.25.135 | 48.4 | 111.8 | 57.7 | 32.8% | 49% |
| IterativeSolvers 0.9.4 | 7.5 | 22.3 | 5.1 | 27.2% | 29% |

- Interpolations 0.16.3 and FFTW 1.10.0 crashed in `inference` stage. Fix #256.
- Cold native inference of library code takes most of `effects` time; warm solve passes inference except Polynomials and Distributions.
- Pure math methods get `possible` writes from MPFR calls: foreign table lacks `mpfr_*`, so each `Ref{BigFloat}` argument stays open.
- `@debug` in SpecialFunctions `beta_inc` adds writes to `_global_logstate`, path regex globals and PCRE contexts; StatsFuns inherits them.
- ForwardDiff blind writes sit in `@eval` methods of `dual.jl`: stand-ins leave value type and partials count of `Dual` open.

### MPFR and GMP foreign calls

- Foreign table had no `mpfr_*` or `__gmp*` name, so each `Ref{BigFloat}` argument stayed open.
- Table entries come from C headers (`mpfr.h` 4.2.2, `gmp.h` 6.3.0): `mpfr_ptr` writes, `mpfr_srcptr` reads. Generator: `gen/foreign/generate.jl`, using Clang.jl.
- Rejected: handwritten table. Roughly 200 entries, and one wrong role gives false definite write.
- Rejected: all 800 header functions. Each needs vetting for global state; corpus calls 213 of them.
- Symbol list holds 218 names: 213 Base 1.13 and SpecialFunctions 2.9.2 calls, and five extras (`mpfr_get_d`, `mpfr_cmp`, `mpfr_swap`, `mpfr_remquo`, `mpfr_strtofr`). Generated table: 208 entries.
- Hand entries: `mpfr_asprintf` (variadic), `mpfr_free_str`, `__gmpz_limbs_write`, `__gmpz_get_str`, `__gmpz_export` (pointer results).
- Left open: `mpfr_set_emin`, `mpfr_set_emax`, `mpfr_clear_flags`, `__gmp_set_memory_functions`, `__gmp_set_alloc_overflow_function` write C global state.
- Rejected: prefix rule. Unknown `mpfr_` name would get a guessed role.
- Test compares the table with a handwritten classification from the manuals.

Job 675 on ssh-dev, both arms in one job (main 51b8b5e3 table against branch table):

| Package | `possible` main | `possible` branch | `bang_definite` |
|---|---|---|---|
| SpecialFunctions 2.9.2 | 90 of 499 | 90 of 499 | 0 to 0 |
| StatsFuns 2.3.1 | 58 of 289 | 58 of 289 | 0 to 0 |
| Distances 0.10.12 | 58 of 188 | 58 of 188 | 29 to 29 |
| DataStructures 0.18.22 | 224 of 947 | 224 of 947 | 203 to 203 |
| JSON 1.13.4 | 85 of 291 | 84 of 291 | 63 to 63 |

- Table alone does not clear SpecialFunctions and StatsFuns. Other sources remain.
- `BigFloat()` reads `CURRENT_PRECISION` (`ScopedValue`). That read gives a code-doubt write to unknown object and a blind write to the global. Each method that makes a `BigFloat` keeps it.
- `airyai(::Complex)` keeps writes to `z.re` and `z.im`: Amos functions (`zairy_`, `zbes*_`) stay open.
- `x.d` of `BigFloat` builds a fresh `BigFloatData` wrapper over the limb memory of `x`. Trace followed memory backing only for element steps, so the table's write on the wrapper reached no parameter.
- Fix: trace also follows backing at `Step.Field(:ptr)` (`MEMORY_POINTER`, `flow.jl`). Write through the wrapper lands on `x`; input operands stay unwritten.

Job 706 on ssh-dev, table arm without `MEMORY_POINTER` against branch:

| Package | `possible` | `definite` | `bang_definite` |
|---|---|---|---|
| SpecialFunctions 2.9.2 | 90 to 90 | 19 to 50 | 0 to 0 |
| StatsFuns 2.3.1 | 58 to 58 | 50 to 51 | 0 to 0 |
| Distances 0.10.12 | 58 to 58 | 35 to 35 | 29 to 29 |
| DataStructures 0.18.22 | 224 to 224 | 203 to 203 | 203 to 203 |
| JSON 1.13.4 | 85 to 84 | 63 to 64 | 63 to 63 |

- Blind writes: DataStructures 272 to 270, JSON unchanged at 93.

### Branch constants

- `ScopedValue` read calls `HAMT.path(trie, key, h, false)`. Generic variant runs copy-on-write branch, so each read wrote `trie.data`.
- Fix (#263): constant `Bool` argument that callee uses as branch condition makes variant. Variant code drops unreached blocks.
- Doubt test: Julia inference resolves same constant, so Corset resolves it too.

Job 727 on winwsl, main 81aa574c against branch:

| Package | `possible` | `blind_write` | warm solve s |
|---|---|---|---|
| SpecialFunctions 2.9.2 | 90 to 69 | 73 to 41 | 2.37 to 2.79 |
| StatsFuns 2.3.1 | 58 to 58 | 58 to 50 | 1.35 to 1.26 |
| Distances 0.10.12 | 58 to 58 | 64 to 64 | 1.70 to 1.67 |
| DataStructures 0.18.22 | 224 to 224 | 270 to 270 | 4.83 to 3.91 |
| JSON 1.13.4 | 84 to 84 | 93 to 93 | 51.67 to 35.46 |

- Job 728 ran on same box during base arm, so base times are high. Compare facts only.

### Element stores

- Base contract store into collection whose `eltype` points to no object stores nothing (#264): Julia converts stored value.
- Corpus facts unchanged (job 728 against base arm of job 727).
- JSON `json!` ESCAPECHARS paths have other source. `collect` over dict generator gives blind `Deep(ESCAPECHARS)`; blind loads then merge heap slots (job 731).
- `json!(::Any, ...)` summary: 605 of 639 writes and 799 of 877 reads are blind. Its self-cycle reruns 3 times, 4.3 s (job 733).

### Lock writes

- `lock(q.lk)` writes lock state inside argument `q`, so `bang-convention` would demand `!` on every thread-safe container method.
- Rejected: exempt all synchronization. Method that returns while it holds lock changes state caller sees.
- Rejected: count every lock write. Base names `lock` and `notify` without `!`; findings would flag balanced use.
- Chosen: exempt balanced use, checked by full dataflow of hold counts. Estimate: about 1.5 times basic pattern check.
- Basic check risk: Base has 663 lock sites in 42 files; missed patterns put blind spots on every caller.
- Exception edges, needed for `finally`, also give hold count at throw exits.
- Throw-exit count is F98 fact. Syntax F98 sees same block only and reports code that cannot throw, so F98 moves to effects stage.
- File pair joins: fresh `open` result is exact place. Distances, DataStructures and JSON have no lock call; fixtures carry tests.

Effect kinds arm 564 and release balance arm 578 on ssh-dev (loaded box, so counts only):

| Arm | Distances | DataStructures | JSON |
|---|---|---|---|
| Warm solve allocation MB | 503 to 558 | 1304 to 1441 | 148713 to 32410 |
| `effects` allocation MB | 1005 to 1072 | 1816 to 1968 | 149789 to 33408 |

- JSON allocation falls 4.6 times. Lock, semaphore and `wait` bodies no longer run, so IO under `@_lock_ios` applies no scheduler stores.
- Distances and DataStructures rise about 10%: balance dataflow runs in each unit.
- Method verdict counts stay. Distances `bang_definite` 35 to 29: six `Mahalanobis` methods that call `@warn` lose one definite write each.
- JSON blind places fall: `json` 781 to 304, `WriteClosure` 388 to 117, `deserialize` 150 to 5.
- Effect kinds against throw paths: JSON allocation 145435 to 149789 MB, on other box and load; no claim.

### Engine cost

- Profile of JSON warm solve: 96% applies callee summaries (`site_place`, `load` through memory backing, `Origin` hash).
- JSON counts: 1.2 flows per variant, 2.1 rounds per flow, 36.5 statements per flow.
- Each round applies whole callee summary: `json!` summary holds 1188 accesses and 489 edges.
- Slot targets: 82% of lookups repeat on unchanged heap; backing chains reach depth 59. Memo per heap state.
- Rounds apply callee stores until targets settle. One settled round then maps callee accesses.
- Origins, nodes and places compare by variant match. Derived Moshi `Eq` finds variant by subtype test: 66 to 124 ns against 4.6 ns.
- Job 632 (winwsl, arms serial), warm solve seconds and MB:

| Arm | JSON | Distances | DataStructures |
|---|---|---|---|
| Main | 98.3, 33535 | 1.80, 564 | 3.76, 1472 |
| Memo | 78.7, 14335 | 2.11, 550 | 3.48, 1368 |
| Settled round | 45.9, 10175 | 2.39, 568 | 3.47, 1418 |
| Variant equality | 43.6, 9621 | 2.36, 568 | 4.99, 1416 |

- Every arm gives same fact lines on every package. Small-package times stay inside box noise.
- Rejected: callee accesses from second round on, without settled round. JSON 53.1 s, 11336 MB.
- Rejected: hand copy of derived hash. Same values, same speed (16 ns per origin).
- Gate stays far: JSON `effects` 50.8 s against `inference` 10.3 s.
- Left: access mapping about 30% of solve, store mapping 28%, `Place` hash with table lookup 20%, table memory 15%.

### Summary cache

- #251 keyed library file by every loaded package: corpus packages shared no entry. #254 keys each entry by its native edge closure.
- Job 656 (macdev under other load, main 65d54fbb before #255), `effects` seconds, hits in brackets:

| Package | No cache | Empty cache | Other package cache | Warm | `inference` |
|---|---|---|---|---|---|
| Distances | 15.8 | 18.6 | — | 12.0 (2245) | 5.2 |
| DataStructures | 23.9 | — | 19.8 (757) | 16.0 (3685) | 9.2 |
| JSON | 188.0 | — | 218.8 (1701) | 176.3 (4476) | 11.4 |

- Every arm gives same fact lines on every package.
- Warm cache saves 24% to 33% on Distances and DataStructures. JSON solve of own units dominates, so cache saves little.
- Empty cache costs about 17%: key walk and store of 6306 entries.
- File holds 24051 entries in 15 MB. Each run reads it, reads it again to merge, and writes it to stamp hits.
- Gate fails with warm cache: Distances 2.3 times `inference`, DataStructures 1.7 times.

### Stateful iterators

- Trigger "every `iterate` on iterator not proven stateless" rejected: single pass is safe for both kinds, so it flags nearly all generic code.
- `Iterators.Stateful` as fix costs allocation and reads one element ahead: one `popfirst!` on `Channel` of three items leaves one.
- Bug is restart: `first`, `isempty` or `iterate` without state, then second pass. F51 widens from `Stateful` to iterator not proven stateless.
- `Iterators.peel` splits first element from rest without lookahead.
- F109: direct `iterate` on known `Stateful` gets `popfirst!` suggestion, so `!` names write.
- `for` lowered to `popfirst!` would break Julia: collections define `popfirst!` as remove, most iterators lack it, `Stateful` fallback reads ahead.
- Non-breaking variant is Rust-style cursor protocol with fallback cursor; Julia 2.0 scope (JuliaLang/julia#43388 asks for statefulness trait).
- F51 is definite and on by default: method that accepts stateful iterator and restarts it has bug in its own code.
- Escape counts: started iterator returned or stored hands on partly consumed iterator; stateless and stateful callers see different elements.

### Numerically unstable formulas

- F110 `unstable-formula`: naive formula where stable function exists. Clippy counterpart `imprecise_flops` is allow-by-default nursery lint.
- Group correctness: `log(sum(exp.([1000.0, 1000.0])))` gives `Inf`; `log(1 + 1e-20)` gives `0.0`, `log1p` gives `1e-20`.
- Inference stage: operands must be `Number`. Matrix forms (`sin(π * A)`) have no stable scalar counterpart.
- Fix tier `likely`: replacement changes rounding. Fix adds LogExpFunctions.jl dependency when needed: small, widely used package.

### Resizing generic arrays

- F111 `generic-resize`: `push!` and other resizing calls on argument annotated `AbstractVector`. Ranges, views, `SVector` and `Memory` cannot grow.
- Julia has no resizable-array type, so annotation cannot state requirement. Rust rejects `push` on `&mut [T]` at compile time.
- ArrayInterface.jl trait `can_change_size` answers question at run time; Base has no counterpart.
- Trait is no fix: default is `false`, and only `Vector`, `AbstractDict` and forwarding wrappers say `true` (7.30). `BitVector` resizes but says `false` (JuliaArrays/ArrayInterface.jl#515).
- Guard on trait rejects resizable types that never opted in, so method gets less generic than bare `push!`. Guard still counts as narrowing.
- Group composability: package-internal callers often pass only `Vector`. Library preset warns; outside callers hit `MethodError` deep inside method.
- F15 is mirror rule: it widens `::Vector`. Resized argument keeps `Vector`, so fixes of F15 and F111 never loop.
- Fix `manual`: caller-allocated output written by index works for every mutable array and avoids growth cost.

### Call site cache and joins

- #265: call site maps callee place with origins below it once per round. Facts same on 5 packages.
- Job 753 (winwsl, second job on box), warm solve seconds: JSON 49.2 to 31.9, DataStructures 9.1 to 5.8, StatsFuns 2.2 to 1.2.
- Rejected: summary keeps blind access on root only. SpecialFunctions `alias` spots rose 32 to 57.
- Root key collided with exact key in dispatch join: possible write lost (JSON 84 to 83).
- #266: blind access of one member and exact access of other member join to `possible`.
- #267: `Methods` callee sorts by module, file, line and signature. Call facts kept hash order before.

### Path certainty

- Place says where access lands; certainty says whether it happens. Coarse place adds no doubt (#268).
- Old cap of 2 steps gave blind spot: `w.chain.next.box.value = v` wrote nothing Corset reported.
- Path follows declared field types. It collapses at recursive concrete type, third abstract step in a row, or past 8 steps.
- Constant global root takes type of its value: binding type of constant is `Any`.
- Callee `deep` write keeps doubt on caller argument. Caller object inside fresh argument stays blind.
- Rejected: blind when declared fields of root reach `IO` or RNG. `n.next.next = n` cannot land in `IO`, yet went silent.
- Rejected: lock in that check. Lock write is write unless release balance proves use balanced.
- Chosen: exempt kind needs proof: written object type, callee kind or root type. Raw write into `IO` memory below collapsed path gives false finding.
- Jobs 772 and 802 (winwsl, serial arms), main against branch:

| Package | `alias` spots | `blind_write` | `possible` | warm solve MB |
|---|---|---|---|---|
| JSON 1.13.4 | 140 to 73 | 93 to 82 | 84 to 84 | 6685 to 8630 |
| DataStructures 0.18.22 | 396 to 161 | 270 to 184 | 225 to 238 | 1147 to 1252 |
| Distances 0.10.12 | 67 to 60 | 64 to 62 | 58 to 58 | 472 to 473 |
| SpecialFunctions 2.9.2 | 32 to 25 | 41 to 39 | 69 to 69 | 654 to 655 |
| StatsFuns 2.3.1 | 38 to 38 | 50 to 50 | 58 to 58 | 392 to 392 |

- Depth 4 arm allocates same as depth 8 (JSON 8610 MB): cap does not drive cost. DataStructures `alias` 168 at depth 4.

### Numeric corpus

- JSON leaves corpus. One generic self-recursive method, `json!(::Any, …)`, holds most of its solve time. Most of its writes are blind.
- Corset targets numeric code first, so JSON measured outlier cost. SpecialFunctions 2.9.2, StatsFuns 2.3.1 and Distributions 0.25.135 replace it.
- Distributions is large generic numeric code: survey warm solve 57.7 s, `inference` 48.4 s.
- Last JSON numbers: warm solve 32 s against `inference` 9–11 s (job 753). Benchmarks still take JSON by argument as stress case.

### Corpus speed check

- Job 838 (winwsl), main ed05f71b, one library cache dir across corpus. First run fills cache; warm run reads it.

| Package | `inference` s | `effects` s first, warm | Warm solve s | `possible` |
|---|---|---|---|---|
| Distances 0.10.12 | 7.29 | 7.28, 6.32 | 3.80 | 30.9% |
| DataStructures 0.18.22 | 12.59 | 14.52, 11.78 | 7.60 | 25.1% |
| SpecialFunctions 2.9.2 | 20.28 | 9.16, 6.89 | 4.27 | 13.8% |
| StatsFuns 2.3.1 | 6.21 | 2.88, 1.51 | 1.12 | 20.1% |
| Distributions 0.25.135 | 31.23 | 32.60, 28.15 | 18.52 | 32.8% |

- Warm `effects` stays at most `inference` on all five. Box ran other jobs, so ratios near 1 carry noise.
- `possible` limit 30% fails on Distances and Distributions.

### Visit order

- `trace` and `load_any` kept doubt of first chain to reach origin. Chain with less doubt found later got lost: access stayed blind.
- Fix: walk origin again when chain lowers its doubt. Test builds both visit orders over two origins; old walks fail one.
- Corpus facts do not change (job 863, winwsl). JSON warm solve allocation drops from 8483 to 7632 MB.
- Open: Distributions facts take one of two sets, 24523 or 24777 lines. Lines differ in `test_mvnormal` only.
- Ten Corset rebuilds kept one set on each of two boxes (jobs 900, 902). Distributions rebuild changed set (job 910).
- Equal native IR gave equal summary for every variant (job 911). Corset steps do not cause the change.
- Native inference narrows `g` to `Union{MvNormal, MvNormalCanon}` after `cov(g)` in some builds only. Narrowing followed `cov(::MvNormal)` result in cache.
- Distributions loaded from source gave both results over three processes (job 931). Julia inference order decides.
- Cause in Julia match loop: it stops once return type is `Any`, and narrowing needs every match seen (job 959).
- So narrowing depends on callee return types, which depend on inference order and cache. Julia master has same logic.
- Corset infers with `NativeInterpreter`, so it shares global cache with package images. Other IR changes rename type variables only.
- Fix: Julia PR #65131 refines arguments from all match signatures, also after early stop.
- Julia 1.13.4 with fix narrowed in all 8 processes: 3 package-image loads, 5 source loads (job 1049).
- Stock 1.13.4 in same job: package-image loads never narrowed; source loads narrowed in 4 of 5.
- Corset facts over Distributions rebuilds (jobs 1064, 1071): stock gave two sets (5 and 7 of 12), fix gave one set (14 of 14).
- Stock sets differ in `test_mvnormal` only. Fix set equals narrowed stock set there.
- Fix also resolves write in `ProductDistribution` constructor (`product.jl:1004`) in every rebuild. Stock counts it on summary line.

### Deep walk

- `deep` pushed each content target once per reference, so shared objects got walked many times. Walk now visits each origin once.
- `extend` builds extended path once.
- Warm solve allocation, main to branch (jobs 858 and 899, winwsl): JSON 8481 to 7288 MB, DataStructures 1257 to 1238, Distributions 4426 to 4358.
- Facts: JSON and DataStructures same as main; Distributions gives one of two sets that change per build ("Visit order").
- Rejected: walk in old push order (7808 MB on JSON). Per-build fact sets explained earlier fact change; order gave nothing.
- Rejected: size hint in `add_all!` (job 854). Hint grew small tables early: JSON 7287 to 8669 MB.
