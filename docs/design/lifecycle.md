# Lifecycle

Array def-use per method: rows 10 and 11 of `phase5.md`.

`effects` stage finds array events per unit; it holds IR. `lifecycle` stage merges units and gives def-use per allocation.
Rules read `lifecycle` facts only. Code lives in `src/Effects/arrays.jl` (events) and `src/Lifecycle.jl` (merge over units).

### Allocations

Allocation: statement whose result is new array that unit code alone holds. Base table gives its kind:

| Kind | Calls |
|---|---|
| `undef` | `similar`; `Array`, `Vector`, `Matrix`, `BitArray` constructor with `undef` operand |
| `filled` | `zeros`, `ones`, `fill`, `trues`, `falses` |
| `broadcast` | `Base.materialize` of `broadcasted` result: `f.(x)` |
| `collected` | `collect`, comprehension (`collect` of `Generator`), `map` |
| `slice` | `getindex` on array with range or `Colon` index operand: `A[:, i]`, `v[2:end]` |
| `copied` | `copy`, `vcat`, `hcat` |

- Package call result is no allocation: name trust tells nothing about whether result is new.
- Result type: `Array`, `BitArray`, or array stand-in (`similar` and broadcast of stand-in keep it). Stand-in stands for caller array type.
- Other result type (`SVector`, GPU array, `OffsetArray`) is no allocation: element and index rules differ.
- Constant dimension operands give length. Else length is unknown.
- Allocation in loop is new array each iteration. Its events count per iteration.

### Identity

- Allocation value: SSA value of allocation, and `π` node or `typeassert` of it.
- View: alias-table result (`effects.md`, Roots) of allocation value. Events through view carry `view`; they never give coverage.
- `.=` target over every element (`a[:] .= x`, `a[1:end] .= x`) is allocation value. Fill loop ranges below cover.
- `φ` node that joins allocation value with other value ends identity: later uses are `unknown` events.
- Loop `φ` that joins allocation before loop with allocation in loop body gives rebind pair (F41).

### Events

Each statement that uses allocation value gives one event, with statement span, callee and operand position. Position counts positional operands only: `kwcall` keywords drop out. Event keeps Base function that call takes as first operand: `vcat` in `reduce(vcat, a)`. `!` call that takes array as written and source operand gives read, then write (`map!(f, a, a)`), or write, then escape when it stores array itself (`fill!(a, a)`). `!` call that reads old elements of array it writes (`sort!`, `reverse!`, `unique!`, `map!(f, a)`) gives read, then write.

- `shape`: `size`, `length`, `axes`, `eachindex`, `firstindex`, `lastindex`, `ndims`, `eltype`, `isempty`, `similar`, `keys`, `LinearIndices`, `CartesianIndices`, `checkbounds`, `isassigned`, `sizeof`, `strides`, `stride`, `===`, `isa`, `typeof`, `isdefined`. Reads no element.
- `read`: `getindex` reads elements at its index operands. `first`, `last` and `only` read one element. `dotview` with scalar index reads element as `getindex`.
- Other non-`!` call reads whole array. So does non-written operand of library `!` call: `copyto!(b, a)` reads `a`.
- `broadcasted` result reads every element of its array operands when broadcast runs.
- `write`: `setindex!` writes elements at its index operands.
- Whole write: written operand of `fill!`, `copyto!` with two operands, `map!`, `broadcast!`, `Base.materialize!` (`a .= …`), `rand!`, `randn!`.
- `copyto!` and `map!` write as many elements as shortest source. Whole only when each source has same extent: array itself, `x` in `similar(x)`, or `x` in `Vector{T}(undef, length(x))`, and no `!` call writes `x`. Else `unknown`.
- Other `!` call on written operand: `unknown` write. It can read first (`sort!`) or write part.
- `resize`: written operand of resize table call (`effects.md`, F48 tables).
- `escape`: return; stored operand of builtin store; closure capture; foreign call operand; pointer conversion; index operand of view (`b[idx] .= 0`), after whole read by bounds check outside `@inbounds`, or count of Boolean mask.
- Other operand of `!` call escapes when type of written operand can hold array (`push!(c, a)`).
- Non-written operand of package `!` call escapes: name promises one written operand, and call can write others. Distances `colwise!(metric, r, a, b)` writes `r`.
- Operand after written operand with call method (functor) of library `!` call escapes: `map!(scale, r, x)` writes `r`. Run of functors passes this on.
- Operand of non-`!` call escapes when result type can hold array: tuple, constructor, abstract result.
- Operand escapes when result type meets its type: call can return it (`float(a)`, package `pass(a) = a`). Unary `*(A)` returns `A`.
- Base copy, collect and reduction calls, `Array` constructors, and arithmetic with two or more operands, read operand whole. Result holds its elements, never operand itself, whatever result type: `vcat` of stand-in gives wrapper type.
- `copy`, `vcat`, `hcat` and `Array` constructors can keep unset slots of reference elements unread: operand of such type escapes.
  - Concatenation of `Array` operands reads slots, as Julia 1.13 does: `vcat` with operand of two or more dimensions, `hcat` of vectors only, operand of three or more dimensions. `hcat` with matrix keeps slots. Unknown dimensions or array type: escape, so no false definite finding.
  - `vcat` of vectors reads slots that convert to promoted element type. Promotion can run package code (`promote_rule`), so Corset misses that read.
- Type can hold array when element or field type meets array type, at most 3 steps deep. Base storage (`Array`, `Dict`, `Set`) holds elements only; view or wrapper also holds fields (`SubArray` parent).
- Index operand keeps constant value. Non-constant index keeps nothing.

### Paths

- `sure`: event runs once on every path from allocation that returns. Path that throws counts as none: guard keeps read `sure`.
- Event block post-dominates allocation block over blocks that reach return, and both blocks share loop nest.
- `branch`: allocation run can skip event. `loop`: event lies in loop that allocation lies outside.
- Order: block order of `sure` events follows dominance. Statements in one block keep IR order.
- Fill loop is one `sure` whole write at loop exit when every condition holds:
  - Loop iterates `eachindex`, `LinearIndices` or `CartesianIndices` of `a`, or of `x` in `a = similar(x)` when no `!` call writes `x`.
  - Or loop iterates `axes(a, 1)` of vector, `1:length(a)` or `1:lastindex(a)` of `Array`, or `1:n` and `Base.OneTo(n)` for `n` in `zeros(n)`.
  - Body writes `a[i]` with iteration value `i`, in block that runs on every iteration.
  - Loop exits only through its header, and its exit block post-dominates allocation block.
- Other loop write is `loop` write with unknown coverage.

### Rebind

Rebind pair: loop header `φ` joins allocation before loop with broadcast in loop body. `.=` keeps behavior when each holds:

- `same_axes`: every array operand of broadcast is `φ` value; scalars may join.
- `same_type`: allocation and broadcast have one concrete type.
- `exclusive`: loop alone sees both arrays:
  - Each loop that holds header also holds allocation, but header loop: one allocation per loop entry.
  - Loop reaches no use of allocation but header `φ` and loop exit `φ` that joins only pair arrays.
  - Use of allocation before loop is no view, lazy broadcast or escape; return is allowed.
  - `φ` value: use in loop dominates broadcast, or is its operand. Use after loop needs no loop exit after broadcast.
  - Broadcast value: use in loop is no view, join or escape but return.

### Facts

- Per package method: `ArrayLife` per allocation: site span, source statement, kind, constant dimensions, events in order, rebind pair.
- Units of method merge by allocation span and source statement: mapping can give two allocations one span. Array of generated method is `lifecycle` blind spot: its units lower other code. Events merge by all fields but path; path of merged event is worst over units.
- Event that one unit lacks is `branch` at best: that unit skips it.
- Dimensions and rebind pair stay only when all units agree. Each rebind condition holds only when it holds in each unit.
- Definite verdict reads `sure` events only. `branch`, `loop` or `view` event that can change verdict gives `possible`.

### Rules

- `temporary-array` (F32): `broadcast` or `collected` allocation whose only events are shape reads and one `sure` read by consuming-table call. Fix `likely` (generator sums in order): `sum(f.(x))` → `sum(f, x)` for reduction that takes function; comprehension → generator; `sum(collect(it))` → `sum(it)`. Other forms `manual`. Fix edits reduction argument at operand position of read: comprehension span is line only. `reduce(vcat, A)` and `reduce(hcat, A)` are exempt: Base concatenates in one allocation.
- `unwritten-element` (F33): `undef` allocation read before write. `sure` read of element that no earlier `sure` write covers is definite; read that path can skip is possible. Fix `manual`.
- `unwritten-element` (F34): `filled` allocation with constant length. `sure` element writes cover part of it; then whole read. Kind `placeholder`. Always `possible`: fill value can be data (`e = zeros(n); e[1] = 1.0`). Fix `manual`.
- `constant-array` (F39): `filled` allocation without write, resize, escape or join. Fix `likely`: swap call for FillArrays.jl `Fill`, `Zeros`, `Ones`, `Trues` or `Falses`, and import it above module code. Package adds FillArrays.jl dependency; callee that requires `Array` rejects lazy array. Site that is no call node gets `manual` fix; `slice-copy` checks its site the same way.
- `slice-copy` (F40): `slice` allocation without write, resize, escape, join or `loop` read. Fix `likely`: `@view(…)` around slice; view aliases parent. Span without exact bytes: `manual`.
- `broadcast-rebind` (F41): rebind pair with `same_axes`, `same_type` and `exclusive`. Fix `likely`: `x = f.(x)` → `x .= f.(x)`. Package call that keeps array but returns no array hides alias. Right side of other assignment: `manual`.
- Fix tiers and messages: row 11.

### Tests

- Fixture package `test/lifecycle/LifecycleCases`: method per allocation kind, event kind, path and fill-loop form.
- Each fixture method states expected `ArrayLife` in test file.
- Runtime check: definite `undef` fixture of `String` elements throws `UndefRefError`. Fill-loop fixtures assign every element (`isassigned`).
