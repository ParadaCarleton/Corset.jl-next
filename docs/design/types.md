# Types

Typed analysis: stand-in types, type-disruption, arguments, unions, sum types.

### No tests

Corset never reads or runs package tests. Signatures come from annotations: stand-in types for generic arguments and struct parameters (from their bounds), declared type otherwise. See **Arguments without stand-in**.

### Arguments without stand-in

- Package abstract type (`s::Shape`): infer once per concrete subtype package defines, with stand-ins for its parameters.
- Function argument: stand-in function returns opaque stand-in result. Method stable under that assumption is exempt: stable whenever `f` is. Problems method causes itself are reported. Code that uses `f`'s result past that point is not analyzed.
- No stand-in yet (`AbstractString`, `AbstractDict`, abstract type without package subtype) and explicit `::Any`: no findings from that argument's data.
- Unannotated method reached from analyzed caller is analyzed through caller inference. Unannotated method nothing calls is skipped; `annotation` reports it.
- Analysis gaps never become findings. Run ends with coverage line: methods not analyzed and reason.

### `type-disruption` engine

**Principle: values from outside inputs are weak.** Literals, constants and globals must not change result type. Inputs combine by normal promotion. Same rule as NumPy 2 for Python scalars.

| Kind | Inputs combine as | Literal or constant | Example finding |
|---|---|---|---|
| Numbers | normal promotion; `Int32` with `Int64` gives `Int64` (pass) | weak: must not widen | `x::Int32 * 2` gives `Int64` |
| Arrays | keep container kind; element types promote | fresh `Array` must not take over container | `x::JLArray .+ zeros(n)` gives `Array` |
| Strings (later) | `String` is correct common type | literal is `String` already | rare; Julia already does this |
| Dicts, sets (later) | keep container kind; key and value types promote | as for arrays | rare |

- **Stand-in types**: types Corset defines to stand for whatever type caller passes, so inference sees concrete type. Numbers: float stand-in and integer stand-in; arrays: stand-in array type. Each is ordinary well-behaved type, and promotes like narrowest real type of its kind: float stand-in absorbs `Int` and loses to `Float64`, like `Float32`; integer stand-in loses to `Int`, like `Int32`. Base code runs on them unchanged.
- **Inference**: infer each package method with stand-in types in place of generic arguments (`::Real`, `T <: Real`, `AbstractArray{T}`). Use native inference and its cache. No JET, no Cthulhu, no custom interpreter.
- **Scan** (family D, package methods only):
  - Literal, constant, global or type name meets input (stand-in, or overspecified argument type): report when converting it to input type would change type of escaping value: returned, or written to argument or global. Intermediate that does not escape (`Float32(x * 0.5)`) goes to `intermediate-widening` (performance). Each site gets one finding.
  - Examples: `x::Int32 * 2` (Int64 vs Int32) and `x::Float32 * 0.5` (Float64 vs Float32) and `Float64(x)` on `Float32` are reported. `x::Float32 * 2` and `x::Int32 / 2` (Float64 either way) pass.
  - Generic `x::Real` runs both number stand-ins, so `x * 2` is reported through integer case.
  - Escape test: own data-flow pass follows value to returns and stores. Escape analysis tracks heap objects only, so it cannot decide this.
  - Definite: narrowest Base type of kind gives concrete counterexample. Promotion rules of user number types are out of scope.
  - Overspecified argument types (`x::Int32`, `v::AbstractVector{Float64}`) are rare in libraries: `overspecified-type` reports them.
  - Branch on type (`x isa Float64`, `T === Float32`): report as `possible`.
- **Why stand-in type**: Base has fast paths for `Float32` and `Float64`. Real float probe takes them; stand-in type takes only generic path, same as user number type.
- **Base**: assume Base callees preserve types; analysis is sound only modulo Base. Optional concrete probes (`Int32`, `Float32`) catch Base-caused widening such as `middle(::Int32)` → `Float64`. Collect real Base widening bugs for upstream report.
- **Scope**: version 1 covers numbers and arrays (F5, F6, F16). Strings and dicts need only new stand-in type and result rule; engine stays same. Interfaces.jl can declare each kind's contract.
- **Cost** (rough estimate, unbuilt): number stand-in type 100–200 lines (promotion, conversion, arithmetic, comparison, `one`/`zero`, `float`, math functions); expect to add methods until inference runs clean on real packages. Mixing check 100–200 lines. Source mapping through TypedSyntax.jl.
- **No tests**: stand-in types come from annotations; see **Arguments without stand-in**.
- Syntax check stays for hard-coded `Array` without template. Shared fix helper finds in-scope type source (`T`, `eltype(x)`, template array).

### Annotations

`::Any` is explicit opt-out. Abstract argument types are intended. `result-conversion` reports result annotation that converts, so annotations act as checks.

### Explicit `Any`

`::Any`, `Vector{Any}`, `Any[]` are approved opt-outs everywhere. `untyped-empty` and `vague-type` exempt them.

### Union policy (`ad-hoc-union`)

One policy for inferred locals, results and struct fields; argument annotations exempt. `Nothing` and `Missing` are free. Members from one module other than Base or Core form variant group. Allow at most one member outside that group.

- Pass: `Union{Circle, Square}`, `Union{DepA.Leaf, DepA.Node}`, `Union{Float64, MyPkg.ParseError}`.
- Report: `Union{Int, Float64}`, `Union{String, Symbol}`.
- Report where union is created: merge in package method, or package declaration.
- Union forwarded unchanged from dependency passes; `confidence = "possible"` reports it.
- Message suggests Moshi.jl ADT.
- Baseline keeps existing findings from failing CI.

### Sum types: Moshi.jl

- One package: Moshi.jl. `@match` matches nested values, tuples, arrays and types; `@derive` writes `==`, `hash` and `show`.
- Moshi detects missing variant only when unmatched value arrives (`error("matching non-exhaustive")`). Its `src/match/verify/` module is empty. F89 and F90 fill gap at lint time.
- Later: offer F89 and F90 logic upstream to fill Moshi `verify/`. Owner approves before any PR.
- Moshi API may change; only F89 to F91 depend on its syntax.

### Suggested abstract type

Always suggest `Real` for floats. `overspecified-type` uses one helper: `float_to_real(typejoin(members))`. Struct field fix is type parameter (`x::T`) only. Property test: applying any fix never creates new finding. Build general mechanism only if test keeps finding conflicts.

### Annotation transition

Helps unannotated package reach full annotations. `annotation` fixer guesses types; message shows evidence for each guess.

- Evidence, strongest first: argument types at package's own call sites, inferred through annotated callers; default values; struct fields argument flows into; operations body applies (arithmetic gives `Number`, indexing and `length` give `AbstractArray`).
- Widen evidence to family: numbers to `Real` (`Integer` when all integer), arrays to `AbstractVector{<:Real}`, struct to nearest abstract supertype; union of at most three families. Keep guess only when it holds every observed type. Scheme comes from legacy typed fixer.
- Result annotation: infer with chosen argument types; map stand-ins back to type parameters. Tier `likely`.
- Argument guess with call-site evidence: tier `breaking`, since narrower annotation can reject callers. Body-use evidence only: tier `manual`.
- After fix, Corset checks again: internal call that no longer matches shows as `never-succeeds`.
- `application` and `script` presets apply `breaking` fixes automatically, so they transition in one run. `library` needs `--tier breaking`.

### Hard-coded arrays

`type-disruption` reports hard-coded `Vector`/`Matrix`/`Array` construction everywhere, `zeros`, `ones`, `fill` included. With template array: autofix to `similar(template, T, dims)`. Without template: message teaches caller-supplied template or array type; autofix adds parameter in `breaking` tier. One shared initializer fixer serves `type-disruption`, `constant-array` and `unwritten-element`.

### Specialization count

`specialization-blowup` predicts from source: C finds methods that specialize on `Function` or `Type` argument; A counts distinct closures or types passed at package call sites. Compiled-instance count from precompile workload: later, opt-in.
