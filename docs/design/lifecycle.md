# Lifecycle

Array def-use per method: rows 10 and 11 of `phase5.md`.

`effects` stage finds array events per unit; it holds IR. `lifecycle` stage merges units and gives def-use per allocation.
Rules read `lifecycle` facts only. Code lives in `src/Effects/arrays.jl` (events) and `src/Lifecycle/` (def-use).

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
- `φ` node that joins allocation value with other value ends identity: later uses are `unknown` events.
- Loop `φ` that joins allocation before loop with allocation in loop body gives rebind pair (F41).

### Events

Each statement that uses allocation value gives one event, with statement span, callee and operand position.

- `shape`: `size`, `length`, `axes`, `eachindex`, `firstindex`, `lastindex`, `ndims`, `eltype`, `isempty`, `similar`, `keys`, `LinearIndices`, `CartesianIndices`, `checkbounds`. Reads no element.
- `read`: `getindex` reads elements at its index operands. Other non-`!` call reads whole array. So does non-written operand of `!` call: `copyto!(b, a)` reads `a`.
- `write`: `setindex!` writes elements at its index operands.
- Whole write: written operand of `fill!`, `copyto!` with two operands, `map!`, `broadcast!`, `Base.materialize!` (`a .= …`), `rand!`, `randn!`.
- Other `!` call on written operand: `unknown` write. It can read first (`sort!`) or write part.
- `resize`: written operand of resize table call (`effects.md`, F48 tables).
- `escape`: return; stored operand of builtin store or `!` call (`push!(c, a)`); closure capture; foreign call operand.
- Operand of constructor, tuple or alias-table call escapes when its result escapes. Operand of other non-`!` call escapes when result type can hold array.
- Index operand keeps constant value. Non-constant index keeps nothing.

### Paths

- `sure`: event block post-dominates allocation block, and both blocks share loop nest. Event runs once per allocation.
- `branch`: allocation run can skip event. `loop`: event lies in loop that allocation lies outside.
- Order: block order of `sure` events follows dominance. Statements in one block keep IR order.
- Fill loop is one `sure` whole write at loop exit when every condition holds:
  - Loop iterates `eachindex(a)`, `LinearIndices(a)`, `CartesianIndices(a)`, `1:length(a)`, or `axes(a, 1)` for vector `a`.
  - Body writes `a[i]` with iteration value `i`, in block that runs on every iteration.
  - Loop exits only through its header, and its exit block post-dominates allocation block.
- Other loop write is `loop` write with unknown coverage.

### Facts

- Per package method: `ArrayLife` per allocation: site span, kind, element type, constant length, events in order, rebind pair.
- Units of method merge by allocation span. Event lists merge by span; path of merged event is worst over units.
- Definite verdict reads `sure` events only. `branch`, `loop` or `view` event that can change verdict gives `possible`.

### Rules

- `temporary-array` (F32): `broadcast` or `collected` allocation whose only events are shape reads and one `sure` read by consuming-table call. Fix: `sum(f.(x))` → `sum(f, x)`; `sum(collect(it))` → `sum(it)`.
- `unwritten-element` (F33): `undef` allocation read before write. Read of element that no earlier `sure` write covers is definite.
- `unwritten-element` (F34): `filled` allocation with constant length. `sure` element writes cover part of it; then whole read. Kind `placeholder`.
- `constant-array` (F39): `filled` allocation without write, resize or escape. Fix: FillArrays.jl `Fill`, `Zeros`, `Ones`.
- `slice-copy` (F40): `slice` allocation without write, resize or escape. Fix: `view` of same indices.
- `broadcast-rebind` (F41): rebind pair whose loop allocation is `broadcast` of array operands that are earlier value or scalars. Fix: `x .= f.(y)`.
- Fix tiers and messages: row 11.

### Tests

- Fixture package `test/lifecycle/LifecycleCases`: method per allocation kind, event kind, path and fill-loop form.
- Each fixture method states expected `ArrayLife` in test file.
- Runtime check: definite `undef` fixture of `String` elements throws `UndefRefError`. Fill-loop fixtures assign every element (`isassigned`).
