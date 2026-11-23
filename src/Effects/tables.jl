using Random: Random, AbstractRNG

# Name trust tables (`effects.md`, Name trust). Entries are library functions; package functions never match.

"""
`!` functions whose written operand is not first: `(name, operand count) => position`. LinearAlgebra docstrings:
`ldiv!(A, B)` and `lmul!(a, B)` overwrite `B`. Owner module must be `LinearAlgebra`.
"""
const WRITE_POSITION = Dict{Tuple{Symbol, Int}, Int}((:ldiv!, 2) => 2, (:lmul!, 2) => 2)

"""Package of LinearAlgebra standard library: owner check of table entries (`library_owner`)."""
const LINEAR_ALGEBRA = Base.PkgId(Base.UUID("37e2e46d-f89d-539d-b4ee-838fcccc9c8e"), "LinearAlgebra")

"""
Library functions whose result can lie beneath an operand: views and wrappers (Base docstrings name each one), element
queries, `identity`, and pointer conversions before foreign call.
"""
const ALIAS_FUNCTIONS = Base.IdSet{Any}(
    Any[
        view, reshape, vec, parent, transpose, adjoint, keys, values, pairs, first, last, only, identity, skipmissing, zip, enumerate, pointer, Base.cconvert, Base.unsafe_convert, Iterators.accumulate, Iterators.cycle, Iterators.drop,
        Iterators.dropwhile, Iterators.filter, Iterators.flatten, Iterators.partition, Iterators.product, Iterators.rest,
        Iterators.reverse, Iterators.take, Iterators.takewhile,
    ],
)

"""Alias functions whose result is element or pointer, not view: iterating result never iterates operand (F48)."""
const ELEMENT_ALIASES = Base.IdSet{Any}(Any[first, last, only, pointer, Base.cconvert, Base.unsafe_convert])

"""`!` functions that change size or key set of collection (Base docstrings): loop over it can skip or repeat elements (F48)."""
const RESIZE_FUNCTIONS = Base.IdSet{Any}(
    Any[
        push!, pushfirst!, pop!, popfirst!, popat!, insert!, deleteat!, delete!, empty!, append!, prepend!, resize!,
        splice!, filter!, keepat!, unique!, merge!, mergewith!, union!, intersect!, setdiff!, symdiff!,
    ],
)

"""Functions that delete from collection: Base `filter!` deletes while iterating `DELETION_SAFE` types (F48)."""
const DELETE_FUNCTIONS = Base.IdSet{Any}(Any[delete!, pop!])

"""
Base collections that Base deletes from while iterating: `filter!` of `IdDict`, `WeakKeyDict` (`filter_in_one_pass!`),
`Set`, `IdSet`, `BitSet` (`unsafe_filter!`). `Set` iterates its `Dict`, so `Dict` counts too.
"""
const DELETION_SAFE = Any[Dict, IdDict, WeakKeyDict, Set, Base.IdSet, BitSet]

"""
`!` functions that give wrong result, or throw, on one object as output and input (F50), by owner (`library_owner`)
and name, to position of input operand that breaks (`nothing`: any). LinearAlgebra docstrings: `mul!` output "must
not be aliased" with inputs; `transpose!`, `adjoint!` give "unexpected results" on "overlapping memory". Base
reductions fill output with init value before they read input. Base `circshift!` and `circcopy!` throw.
`splice!(a, indices, replacement)` copies replacement after resize frees its slots; index operand reads before resize.
"""
const ALIAS_BREAKS = Dict{Tuple{Symbol, Symbol}, Union{Nothing, Int}}(
    (:Base, :sum!) => nothing, (:Base, :prod!) => nothing, (:Base, :any!) => nothing, (:Base, :all!) => nothing,
    (:Base, :count!) => nothing, (:Base, :splice!) => 3, (:Base, :circshift!) => nothing, (:Base, :circcopy!) => nothing,
    (:LinearAlgebra, :mul!) => nothing, (:LinearAlgebra, :transpose!) => nothing, (:LinearAlgebra, :adjoint!) => nothing,
)

"""
`!` functions that copy aliased input first (F50): Base `copyto!` and `setindex!` on arrays call `Base.unalias`;
`copy!` calls `copyto!`; `prepend!` unaliases items; broadcast `preprocess` calls `broadcast_unalias`.
"""
const UNALIAS_FUNCTIONS = Base.IdSet{Any}(Any[copyto!, copy!, setindex!, prepend!, broadcast!, Broadcast.materialize!])

"""Library functions whose result is one of their operands: each operand is an alternative (Base docstrings)."""
const CHOICE_FUNCTIONS = Base.IdSet{Any}(Any[something, coalesce, max, min, ifelse])

"""
Library functions whose result can be element of container operand, or other operand: lookups with default, removals,
reductions, random choice and channel takes (Base docstrings).
"""
const ELEMENT_FUNCTIONS = Base.IdSet{Any}(Any[get, get!, getkey, pop!, popfirst!, popat!, maximum, minimum, reduce, foldl, foldr, Random.rand, take!, fetch])

"""Element functions whose third operand is default result: `get(d, k, default)`, `pop!(d, k, default)`."""
const DEFAULT_FUNCTIONS = Base.IdSet{Any}(Any[get, get!, getkey, pop!, popat!])

"""Base IO functions: each writes its `IO` operands (IO kind). Printing without `IO` operand writes `stdout`."""
const IO_FUNCTIONS = Base.IdSet{Any}(
    Any[
        write, print, println, show, display, flush, close, read, readline, readlines, readuntil, readchomp,
        readavailable, unsafe_read, unsafe_write, peek, seek, seekstart, seekend, skip, eof, printstyled,
    ],
)

"""Base printing functions: without `IO` operand they write `stdout`."""
const STDOUT_FUNCTIONS = Base.IdSet{Any}(Any[print, println, show, display, printstyled])

"""Base synchronization functions: each writes its first non-callable operand (synchronization kind)."""
const SYNC_FUNCTIONS = Base.IdSet{Any}(Any[lock, unlock, trylock, wait, notify, Base.acquire, Base.release, schedule, yieldto])

"""Random functions: each advances its `AbstractRNG` operand, or default RNG without one."""
const RNG_FUNCTIONS = Base.IdSet{Any}(
    Any[Random.rand, Random.randn, Random.randexp, Random.bitrand, Random.randstring, Random.randperm, Random.randcycle, Random.shuffle, Random.randsubseq],
)

"""Iterator types whose `iterate` removes element: `iterate` on them writes iterator (Base docstrings); `eachline` result by name."""
const STATEFUL_ITERATORS = Any[Iterators.Stateful, Channel]

"""Functions that start iteration of their operand without state (`effects.md`, Reads); `isempty` only by generic method."""
const START_FUNCTIONS = Base.IdSet{Any}(Any[first, only, isempty])

"""Library functions that iterate each non-callable operand (`effects.md`, Reads, consuming table)."""
const CONSUMING_FUNCTIONS = Base.IdSet{Any}(
    Any[collect, sum, prod, map, filter, foreach, reduce, mapreduce, foldl, foldr, any, all, count, maximum, minimum, extrema, join],
)

"""Functions that read task-local state (task-local kind)."""
const TASK_FUNCTIONS = Base.IdSet{Any}(Any[current_task, task_local_storage])

"""Builtins that store into first operand: `setfield!` family and memory stores (`effects.md`, Writes, source 1)."""
const STORE_BUILTINS = Base.IdSet{Any}(
    Any[setfield!, Core.swapfield!, Core.modifyfield!, Core.replacefield!, Core.setfieldonce!, Core.memoryrefset!, Core.memoryrefswap!, Core.memoryrefmodify!, Core.memoryrefreplace!, Core.memoryrefsetonce!],
)

"""Pointer store intrinsics: each writes memory its first operand points to, or below (`unsafe_store!` calls them)."""
const POINTER_STORES = Base.IdSet{Any}(
    Any[Core.Intrinsics.pointerset, Core.Intrinsics.atomic_pointerset, Core.Intrinsics.atomic_pointerswap, Core.Intrinsics.atomic_pointermodify, Core.Intrinsics.atomic_pointerreplace],
)

"""Builtins that store into global binding named by module and symbol operands."""
const GLOBAL_BUILTINS = Base.IdSet{Any}(Any[setglobal!, Core.swapglobal!, Core.modifyglobal!, Core.replaceglobal!, Core.setglobalonce!])

"""Builtins whose result lies at step below first operand: field load and memory reference."""
const LOAD_BUILTINS = Base.IdSet{Any}(Any[getfield, Core.memoryrefnew, Core.memoryrefget, Core.memoryref_isassigned])
