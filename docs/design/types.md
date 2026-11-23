# Types

Typed analysis: stand-in types, type-disruption, lost narrowing, arguments, unions, sum types.

### No tests

Corset never reads or runs package tests. Signatures come from annotations: stand-in types for generic arguments and struct parameters (from their bounds), declared type otherwise. See **Arguments without stand-in**.

### Array stand-ins

- Array argument takes array stand-in shaped as its annotation: stand-in kind replaces container, element and dimensions keep annotation bounds.
- `AbstractVector` gives `ArrayStandIn{<:Any, 1}`. `AbstractArray` gives `ArrayStandIn` with open dimensions. `AbstractVecOrMat` gives one stand-in per member.
- Element bound below `Any` that number stand-ins fit takes them, as number argument does: `AbstractVector{<:Real}` gives float and integer elements.
- Number stand-in elements keep float promotion that `type-disruption` reads (`xs .* 0.5`).
- Other element stays open (`ArrayStandIn{<:AbstractString, 1}`). Concrete `Any` element decides element-type calls: `oneunit(eltype(xs))` fails, so loop body is dead.
- `DenseArray` and `StridedArray` bounds take `DenseStandIn`.
- Open stand-in is not concrete. Call reaches untyped method when each argument type is concrete once its variables take their bounds (view of open stand-in too).

### Arguments without stand-in

- Package abstract type (`s::Shape`): infer once per concrete subtype package defines, with stand-ins for its parameters.
- Struct parameter takes every stand-in its bound fits, package struct stand-ins included (`Outer{S <: Inner}`).
- Struct parameter no stand-in fits takes its bound. Field of type `Any` acts as `::Any` argument: its data gives no findings.
- Struct that bound makes empty gets no stand-in: `Sized{N}` with `N = Any` has field type `Union{}`.
- Union or abstract argument takes first stand-in of each struct before second of any, so cut at signature limit reaches most structs.
- Macro that rebuilds struct (`@concrete struct`) gives constructors its own file; struct ties to its form by name.
- Function argument: stand-in function returns `Any` (inference barrier). Its call has unknown compiler effects, so compaction keeps it; `effects` reads it as call of function value without name. Method stable under that assumption is exempt: stable whenever `f` is. Problems method causes itself are reported. Code after `f`'s result stays analyzed; values from that result give no findings. Opaque result type truncates inference frames.
- No stand-in yet (`AbstractString`, `AbstractDict`, abstract type without package subtype) and explicit `::Any`: no findings from that argument's data.
- Unannotated method reached from analyzed caller is analyzed through caller inference: `inference` stage keeps explicit worklist of package frames reached from stand-in callers. Unannotated method nothing calls is skipped; `annotation` reports it. Expect low coverage on unannotated packages (Distances: 165 of 283 methods) until `annotation` fixer runs.
- Method Corset cannot analyze is blind spot: coverage line counts it with reason.

### `type-disruption` engine

**Principle: values from outside inputs are weak.** Literals, constants and globals must not change result type. Inputs combine by normal promotion. Same rule as NumPy 2 for Python scalars.

| Kind | Inputs combine as | Literal or constant | Example finding |
|---|---|---|---|
| Numbers | normal promotion; `Float32` with `Float64` gives `Float64` (pass) | weak: must not widen float input | `x::Float32 * 0.5` gives `Float64` |
| Arrays | keep container kind; element types promote | fresh `Array` must not take over container | `zeros(n)` returned for `JLArray` input |
| Strings (later) | `String` is correct common type | literal is `String` already | rare; Julia already does this |
| Dicts, sets (later) | keep container kind; key and value types promote | as for arrays | rare |

- **Stand-in types**: types Corset defines to stand for whatever type caller passes, so inference sees concrete type. Numbers: float stand-in and integer stand-in; arrays: stand-in array type. Each is ordinary well-behaved type, and promotes like narrowest real type of its kind: float stand-in absorbs `Int` and loses to `Float64`, like `Float32`; integer stand-in loses to `Int`, like `Int32`. Base code runs on them unchanged. Array stand-in has `OneTo` axes and column-major memory: rules about axes or memory order read declared argument type, never stand-in.
- **Inference**: infer each package method with stand-in types in place of generic arguments (`::Real`, `T <: Real`, `AbstractArray{T}`). Use native inference and its cache. No JET, no Cthulhu, no custom interpreter.
- **Scan** (`inference` stage, package methods only):
  - Weak value: number literal, constant, call of weak values only (`sqrt(2)`, `2π`, `(1.0, 2.0)`), variable assigned one (`s = 0`), or Base number type name as callee, `convert` target or broadcast function.
  - Float input only. Julia promotes small integers to `Int` on purpose (`sum(Int32[1])` is `Int64`; index math runs in `Int`), so integer input takes no part.
  - Integer and float weak values convert to float stand-in. Type name counts when it widens float input (`Float64(x)`); model (`Float32(x)`), narrower type (`Float16(x)`) and other kind (`Int(x)`) pass.
  - Meeting: call takes weak value and argument that holds float stand-in. With weak value converted, result type changes. Input absorbs weak value: with input swapped to `Float64`, conversion changes nothing. Pair, tuple and struct with own parameter per field fail this test (`x => 0.5`), and so does default value (`get(table, x, 0.5)`). Lazy broadcast compares array it materializes to. Builtins (`getfield(t, 2)`) change no result type.
  - Report when converting weak value to input type would change type of escaping value: returned, or written to argument, global or local container method returns. Intermediate that does not escape (`Float32(x * 0.5)`) goes to `intermediate-widening` (performance). Each site gets one finding.
  - Examples: `x::Float32 * 0.5` (Float64 vs Float32) and `Float64(x)` on `Float32` are reported. `x::Float32 * 2` passes; `x::Int32 * 2` and `x::Int32 / 2` pass as integer input.
  - Generic `x::Real` runs both number stand-ins; float case reports `x * 0.5`.
  - Escape test: differential inference. Copy lowered code, convert every meeting weak value to stand-in type, and run native inference on copy. Converted value meets more input (`x * 2.0 + 1.0`), so rounds repeat until no new meeting. Then each weak value stays unconverted alone: changed returned or stored type is escape; changed number intermediate only is widening. Escape analysis tracks heap objects only, so it cannot decide this.
  - Store: `setindex!`, `setproperty!`, `push!`, `materialize!` (`.=`) and others into argument, or `setglobal!`. Concrete element, dictionary value, field or global type converts value.
  - Weak value whose conversion makes reached call throw is dropped, and stays dropped in later rounds: callee takes only `Float64` there.
  - **No downstream consequence, no finding**: disruption is correct when every use converts value back before it matters. Integer input takes no part, so index math (`heapleft(i::Integer) = 2i` feeding `a[heapleft(i)]`) gives no finding. Store into concrete field, element or dictionary value type converts.
    - Exact rule, not built: follow widened value through returns into package call sites; exempt when every path ends in conversion. Public function with unknown callers: report as `possible`.
  - Definite: `Float32` gives concrete counterexample. Promotion rules of user number types are out of scope.
  - Overspecified argument types (`x::Int32`, `v::AbstractVector{Float64}`) are rare in libraries: `overspecified-type` reports them.
  - Branch on type (`x isa Float64`, `T === Float32`): report as `possible`.
  - Fix (`likely`): convert float weak value to input type. Source of input type, in order: static parameter bound to float stand-in (`T(0.5)`), argument of float stand-in type (`oftype(x, 0.5)`), array argument of float stand-in elements (`eltype(xs)(0.5)`).
  - Fix wraps source in `float` when declaration admits integers (`x::Real` gives `oftype(float(x), 0.5)`); `oftype(1, 0.5)` throws. Argument name must stay unassigned in method.
  - Fix stays `manual` for irrational value, start value of variable, Base type conversion, product `2.0x`, and code inside macro that rewrites calls (`@.`).
  - Test: fixed copy of UI case loses every finding fix applies to.
- **Why stand-in type**: Base has fast paths for `Float32` and `Float64`. Real float probe takes them; stand-in type takes only generic path, same as user number type.
- **Base**: assume Base callees preserve types; analysis is sound only modulo Base. Optional concrete probes (`Int32`, `Float32`) catch Base-caused widening such as `middle(::Int32)` → `Float64`. Collect real Base widening bugs for upstream report.
- **Scope**: version 1 covers numbers and arrays (F5, F6, F16). Strings and dicts need only new stand-in type and result rule; engine stays same. Interfaces.jl can declare each kind's contract.
- **Stand-in fidelity**: stand-in copies every `Float32` and `Int32` special case that changes result type: irrational rule (`irrationals.jl`); `sum`, `prod` and `factorial` widen `Int32` to `Int`. Reflection on stand-in (`fieldnames`, `propertynames`) sees wrapper; inference stage treats its result as opaque. Stand-in test suite runs `Test.detect_ambiguities` against Base and compares inferred result types with model type.
- **No tests**: stand-in types come from annotations; see **Arguments without stand-in**.

### `lost-narrowing` scan

- Lowering stores value of `a && b` in variable when guard `|| exit` or `if !(…)` branches on it. Inference narrows variable on branch of type test only, so narrowing ends inside chain.
- Lowering branches directly on `||` chain, ternary condition and `if a && b`, so narrowing stays there. Condition stored in variable (`ok = a || b`) loses it.
- Scan (`inference` stage, `Narrowing`): follow control flow of typed code as inference does. Also carry what each variable that holds condition proves when true and when false.
- Type tests: `x isa T` with constant `T`, `x === nothing`, `x !== nothing`, `isnothing(x)`, and their negation.
- Loss: read where scan proves narrower type than inference gives at start of block. Inference keeps variable types per block, so check needs no second inference.
- Exception handler proves nothing: it can run after any statement of `try` body.
- Report loss when test maps to term of `&&` or `||` chain; other losses give no finding. One finding per test; first read is cause span.
- Fix: one guard per term, `safe`. Guard must be own statement with unused value, exit must leave block (`return`, `continue`, `break`, `throw`, `error`, `rethrow`), and no comment may sit inside. Else `manual`.

### Annotations

`::Any` is explicit opt-out. Abstract argument types are intended. `result-conversion` reports result annotation that converts, so annotations act as checks.

### Explicit `Any`

`::Any`, `Vector{Any}`, `Any[]` are approved opt-outs everywhere. `untyped-empty` and `vague-type` exempt them.

### Union policy (`ad-hoc-union`)

One policy for inferred locals, results and struct fields; argument annotations exempt. Policy reads one stand-in signature at a time; results of different signatures never merge. `Nothing` and `Missing` are free. Members from one module other than Base or Core form variant group. Allow at most one member outside that group.

- Pass: `Union{Circle, Square}`, `Union{DepA.Leaf, DepA.Node}`, `Union{Float64, MyPkg.ParseError}`.
- Report: `Union{Int, Float64}`, `Union{String, Symbol}`.
- Report where union is created: merge in package method, or package declaration.
- Union forwarded unchanged from dependency passes; `confidence = "possible"` reports it.
- Message suggests Moshi.jl ADT.
- Baseline keeps existing findings from failing CI.

### Sum types: Moshi.jl

- One package: Moshi.jl. `@match` matches nested values, tuples, arrays and types; `@derive` writes `==`, `hash` and `show`.
- Moshi detects missing variant only when unmatched value arrives (`error("matching non-exhaustive")`).
- Corset has no `@match` rules. Exhaustiveness and unreachable-arm checks belong in Moshi `src/match/verify/`, which sees loaded ADT at macro expansion.
- Branch over cases has two correct forms. Cases others extend: dispatch on subtypes (`closed-struct`). Fixed cases: Moshi `@data`, so `@match` checks exhaustiveness.
- Base `@enum` is neither: nobody extends it, and no check finds unhandled case. `unchecked-enum` reports it.
- Ordered enum becomes order chain: `@data Tier begin Safe() < Likely() < Manual() end` defines `isless` by chain position.
- Order chain names every variant, holds singletons only, uses one operator (`<` smallest first, `>` largest first). Ordered type is immutable.
- Corset code uses Moshi `@data` for sum types with data. EnumX enums move to Moshi with `unchecked-enum`.

### Suggested abstract type

Always suggest `Real` for floats. `overspecified-type` uses one helper: `float_to_real(typejoin(members))`. Struct field fix is type parameter (`x::T`) only. Argument fix stays `likely` only when widened method and each other method of function are disjoint or nested; otherwise it is manual. Fix is manual for function package code tests for methods (`applicable`, `hasmethod`, `which`, `methods`, `catch` of `MethodError`): widening changes what that code does. Property test: applying any fix never creates new finding. Build general mechanism only if test keeps finding conflicts.

### Annotation transition

Helps unannotated package reach full annotations. `annotation` fixer guesses types; message shows evidence for each guess.

- Evidence, strongest first: argument types at package's own call sites, inferred through annotated callers; default values; struct fields argument flows into; operations body applies (arithmetic gives `Number`, indexing and `length` give `AbstractArray`).
- Widen evidence to family: numbers to `Real` (`Integer` when all integer), arrays to `AbstractVector{<:Real}`, struct to nearest abstract supertype; union of at most three families. Keep guess only when it holds every observed type. Scheme comes from legacy typed fixer.
- Result annotation: infer with chosen argument types; map stand-ins back to type parameters. Tier `likely`.
- Argument guess with call-site evidence: tier `breaking`, since narrower annotation can reject callers. Body-use evidence only: tier `manual`.
- After fix, Corset checks again: internal call that no longer matches shows as `never-succeeds`.
- `application` and `script` presets apply `breaking` fixes automatically, so they transition in one run. `library` needs `--tier breaking`.
- Built (`Guesses.annotation_guesses`): call-site evidence comes from every inferred caller, concrete or stand-in, with result type at call. Typed method adds results of its own stand-in inference. Literal default value adds its type.
- Result guess is `likely` only when own inference covers every argument type. Untyped keyword, signatures over limit, crash or missing code make it `breaking`: results then miss some argument types.
- `annotation` stays `syntax` stage with `fix_stage = inference`: run computes inference facts when rule is on, so fix never depends on other rules. Without package, fix stays `manual`.
- Partial guess (some causes) applies; next run guesses rest. UI test applies fixes until only `manual` fixes remain, at most three rounds.
- Not built: struct field flow and body-use evidence (`manual` tier). Keyword arguments get no guess.
- Revisit after phase 4: evidence ranking, widening and tiers are first guesses. Measure on corpus how many guesses survive review; adjust. Candidate extra sources: docstring signatures, opt-in run-time type trace, LLM handoff for `manual` guesses.

### Hard-coded arrays

`type-disruption` reports hard-coded `Array` construction in method with input array (`HardArrays` scan, `inference` stage).

- Construction: `zeros`, `ones`, `fill`, `similar(Vector{T}, dims)`, and `Array` type called with `undef` (`Vector{T}(undef, n)`).
- Template: argument of stand-in array type. Prefer argument that dimensions read (`zeros(length(ys))` takes `ys`); else first.
- Scan: put `StandIns.Templated` callee in place of constructor in copy of lowered code, so result takes template's stand-in array type. Then leave each construction unconverted alone, as `Widening` does.
- Escape (returned, or stored where store does not convert): `definite`. Meeting (call takes construction and array from input, `buffer .= xs`): `possible`, since mixing fails only for some array types (GPU).
- Callee that takes `Array` only drops construction, as weak number that makes call throw.
- No input array: no finding. Method has no caller's array type to keep, and adding array type parameter changes its API.
- Fix (`likely`): `zeros(n)` gives `fill!(similar(xs, Float64, n), 0.0)`; `zeros(T, n)` gives `fill!(similar(xs, T, n), zero(T))`; `Vector{T}(undef, n)` and `similar(Vector{T}, n)` give `similar(xs, T, n)`.
- Fix stays `manual` for `fill` value other than literal or name (it would run twice), type without parameter, no dimensions, and reassigned template.
- Messages name container only (`Vector`): element type of stand-in would print as its model.
- Later: `constant-array` (FillArrays.jl) and `unwritten-element` may share fix text builder.

### Specialization count

`specialization-blowup` predicts from source: `package` stage finds methods that specialize on `Function` or `Type` argument; `syntax` stage counts distinct closures or types passed at package call sites.
