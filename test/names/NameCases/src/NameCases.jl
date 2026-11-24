"""Name tier fixture: one method per write source, alias table entry, exception table entry and read kind."""
module NameCases

using LinearAlgebra: LinearAlgebra
using Random: Random, AbstractRNG
using Base.ScopedValues: ScopedValue

"""Mutable cell."""
mutable struct Box
    value::Int
end

"""Immutable holder of one box."""
struct Holder
    box::Box
end

"""Counter that `bump!` advances."""
const COUNTER = Ref(0)

"""Non-constant typed global."""
total::Int = 0

"""Scoped level."""
const LEVEL = ScopedValue(1)

# Builtin store: definite write on object that holds field.
"""Store `value` into `box` by builtin."""
store_field!(box::Box, value::Int)::Nothing = (setfield!(box, :value, value); nothing)
"""Store `value` into `box`."""
set_value!(box::Box, value::Int)::Nothing = (box.value = value; nothing)
"""Store `value` into box of `holder`."""
set_inner!(holder::Holder, value::Int)::Nothing = (holder.box.value = value; nothing)
"""Store into either box: branch decides which object changes."""
set_either!(left::Box, right::Box, pick::Bool)::Nothing = ((pick ? left : right).value = 0; nothing)

# `!` call: written operand by style guide order.
"""Push `value` onto `items`."""
push_value!(items::Vector{Int}, value::Int)::Vector{Int} = push!(items, value)
"""Map `source` into `target`: leading function operand is skipped."""
map_into!(target::Vector{Int}, source::Vector{Int})::Vector{Int} = map!(abs, target, source)
"""Shuffle `items` with `generator`: leading RNG operand is skipped and advanced."""
shuffle_with!(generator::AbstractRNG, items::Vector{Int})::Vector{Int} = Random.shuffle!(generator, items)
"""Reseed default RNG: `!` call without operand writes global state."""
reseed!()::Nothing = (Random.seed!(); nothing)
"""Solve in place: `ldiv!(A, B)` writes `B`."""
solve_upper!(factor::LinearAlgebra.UpperTriangular{Float64, Matrix{Float64}}, rhs::Vector{Float64})::Vector{Float64} = LinearAlgebra.ldiv!(factor, rhs)
"""Call package `!` method: name trust covers package callees."""
call_setter!(box::Box)::Nothing = set_value!(box, 1)
"""Write `box` without `!` in name: breaks convention."""
sneaky(box::Box)::Nothing = (box.value = 1; nothing)
"""Call convention breaker: its write stays unseen here."""
call_sneaky(box::Box)::Nothing = sneaky(box)

# Exception table: library functions without `!` that write.
"""Print `value` to `io`."""
print_value(io::IO, value::Int)::Nothing = print(io, value)
"""Print `value` to `stdout`."""
shout(value::Int)::Nothing = println(value)
"""Draw from `generator`."""
draw(generator::AbstractRNG)::Float64 = Random.rand(generator)
"""Draw from default RNG."""
draw_default()::Float64 = Random.rand()
"""Hold `guard`."""
hold(guard::ReentrantLock)::Nothing = lock(guard)
"""Take next element of `channel`: iteration removes it."""
take_next(channel::Channel{Int}) = iterate(channel)

# Foreign call: possible write on pointer operands.
"""Zero bytes of `items` through C."""
zero_bytes!(items::Vector{UInt8})::Nothing = (ccall(:memset, Ptr{Cvoid}, (Ptr{UInt8}, Cint, Csize_t), items, 0, length(items)); nothing)

# Closure: call that takes or calls closure writes through captured fields.
"""Collect `items` into `out` through closure."""
collect_into!(out::Vector{Int}, items::Vector{Int})::Nothing = (foreach(item -> push!(out, item), items); nothing)
"""Build writing closure without calling it."""
make_callback(items::Vector{Int}) = () -> push!(items, 1)
"""Pass writing closure through alias function: `identity` never calls it."""
wrap_callback(items::Vector{Int}) = identity(() -> push!(items, 1))
"""Hash writing closure: compiler proves call `effect_free`, so it never runs closure."""
hash_callback(items::Vector{Int})::UInt = hash(() -> push!(items, 1))
"""Store writing closure: `push!` stores operand after written one."""
register!(callbacks::Vector{Function}, items::Vector{Int})::Vector{Function} = push!(callbacks, () -> push!(items, 1))
"""Build writing closure and call it."""
call_callback!(items::Vector{Int})::Vector{Int} = (callback = () -> push!(items, 1); callback())

# Keyword-only `!` call: written operand hides in keyword tuple.
"""Push onto keyword `items`."""
keyword_push!(; items::Vector{Int} = Int[])::Vector{Int} = push!(items, 1)
"""Forward `items` as keyword."""
forward_keyword!(items::Vector{Int})::Vector{Int} = keyword_push!(; items)

# Consuming function and pointer store.
"""Collect every element of `channel`: consumes it."""
drain(channel::Channel{Int})::Vector{Int} = collect(channel)
"""Collect first element of `channel` through wrapper: consumes it."""
take_one(channel::Channel{Int})::Vector{Int} = collect(Iterators.take(channel, 1))
"""Collect pairs from `channel` and vector: `zip` consumes channel."""
zip_drain(channel::Channel{Int})::Vector{Tuple{Int, Int}} = collect(zip(channel, [2]))
"""Whether zip of `channel` and vector is empty: `isdone` of each part gives `missing`, so `isempty` takes element."""
zip_empty(channel::Channel{Int})::Bool = isempty(zip(channel, [2]))
"""Whether zip of `channel` and `items` is empty: `isempty` takes element of channel; vector restarts unchanged."""
zip_empty_items(channel::Channel{Int}, items::Vector{Int})::Bool = isempty(zip(channel, items))
"""Collect pairs of `channel` and `items`: only channel is consumed."""
zip_collect_items(channel::Channel{Int}, items::Vector{Int})::Vector{Tuple{Int, Int}} = collect(zip(channel, items))
"""Stateful `isdone` gives `Bool`, channel `isdone` `missing`: `isempty` of zip may take element of each."""
zip_maybe_empty(lines::Iterators.Stateful{Vector{Int}, Union{Nothing, Tuple{Int, Int}}}, channel::Channel{Int})::Bool = isempty(zip(lines, channel))
"""Collect elements of every channel: `flatten` consumes them."""
flatten_drain(channels::Vector{Channel{Int}})::Vector{Int} = collect(Iterators.flatten(channels))
"""First element of `channel`: consumes it."""
first_of_channel(channel::Channel{Int})::Int = first(channel)
"""Store `item` into `containers`, then fill it through load."""
store_then_fill!(containers::Vector{Vector{Int}}, item::Vector{Int})::Vector{Int} = (push!(containers, item); fill!(containers[end], 0))
"""Binary tree node."""
mutable struct Node
    left::Union{Nothing, Node}
    right::Union{Nothing, Node}
    value::Int
end
"""Zero node at end of `path`: loop reaches more exact places than one value keeps."""
function zero_at!(node::Node, path::Vector{Bool})::Nothing
    current = node
    for turn in path
        next = turn ? current.left : current.right
        next isa Node || return nothing
        current = next
    end
    current.value = 0
    return nothing
end
"""Row of boxes whose `eltype` throws: analysis reads element type from declared supertype."""
struct BoxRow <: AbstractVector{Box}
    boxes::Vector{Box}
end
Base.size(row::BoxRow) = size(row.boxes)
Base.getindex(row::BoxRow, index::Int) = row.boxes[index]
Base.eltype(::Type{BoxRow}) = error("no element type")
"""Set value of first box in `row`."""
set_first!(row::BoxRow)::Nothing = (row[1].value = 3; nothing)
"""Zero first box of `pair` by field position."""
zero_left!(pair::Tuple{Box, Box})::Nothing = (getfield(pair, 1).value = 0; nothing)
"""Zero box at `index` of `pair`: field position is unknown."""
zero_at_index!(pair::Tuple{Box, Box}, index::Int)::Nothing = (getfield(pair, index).value = 0; nothing)
# Interpolation embeds vector literal in code; no binding names it.
@eval push_literal!(value::Int)::Vector{Int} = push!($(Int[]), value)
"""Zero box that `ref` holds: `Ref` has no element type, so step type is `Any`."""
zero_ref!(ref::Base.RefValue{Box})::Nothing = (ref[].value = 0; nothing)
"""Wrap `items` and new vector, then fill first: load from fresh vector can give fresh object."""
function fill_wrapped!(items::Vector{Int})::Nothing
    wrapped = Vector{Vector{Int}}()
    push!(wrapped, items)
    push!(wrapped, Int[])
    fill!(wrapped[1], 0)
    return nothing
end
"""Push every element of `extra` onto `items`: splat hides written position."""
push_all!(items::Vector{Int}, extra::Vector{Int})::Vector{Int} = push!(items, extra...)
"""Items that `collect_local!` logs."""
const SEEN = Int[]
"""Collect `items` into `out` through local copy of captured field; log each item to `SEEN`."""
collect_local!(out::Vector{Int}, items::Vector{Int})::Nothing = (foreach(item -> (target = out; push!(target, item); push!(SEEN, item)), items); nothing)
"""Push into local that holds captured `out`, then new vector: write on `out` is possible."""
swap_local!(out::Vector{Int}, items::Vector{Int})::Nothing = (foreach(item -> (target = out; target = Int[]; push!(target, item); push!(SEEN, item)), items); nothing)
"""Push into local that holds new vector, then captured `out` on later rounds: loop reaches write after assignment."""
function loop_local!(out::Vector{Int}, items::Vector{Int})::Nothing
    foreach(items) do item
        target = Int[]
        for _ in 1:2
            push!(target, item)
            push!(SEEN, item)
            target = out
        end
    end
    return nothing
end
"""Store 7 through `pointer`."""
poke!(pointer::Ptr{Int})::Nothing = (Core.Intrinsics.pointerset(pointer, 7, 1, 1); nothing)

# Call results: iteration and element functions give elements; other results can hold operand objects.
"""Zero every box of `boxes` in loop."""
function zero_all!(boxes::Vector{Box})::Nothing
    for box in boxes
        box.value = 0
    end
    return nothing
end
"""Zero first box of `pair` by destructuring."""
zero_first_pair!(pair::Tuple{Box, Box})::Nothing = ((left, _) = pair; left.value = 0; nothing)
"""Zero first box of copy of `boxes`: shallow copy holds same boxes."""
zero_copied!(boxes::Vector{Box})::Nothing = (copy(boxes)[1].value = 0; nothing)
"""Push onto copy of `items`: copy of integers holds no caller object."""
grow_copy(items::Vector{Int})::Vector{Int} = push!(copy(items), 1)
"""Zero box under `:a` in `table`, or new box."""
zero_lookup!(table::Dict{Symbol, Box})::Nothing = (get(table, :a, Box(0)).value = 0; nothing)
"""Push `value` onto group `key` of `groups`, made on first use."""
group!(groups::Dict{Symbol, Vector{Int}}, key::Symbol, value::Int)::Nothing = (push!(get!(Vector{Int}, groups, key), value); nothing)
"""Push onto entry `key` of `table`, or new vector: key is never result."""
push_lookup!(table::Dict{Vector{Int}, Vector{Float64}}, key::Vector{Int})::Nothing = (push!(get(table, key, Float64[]), 1.0); nothing)
"""Push onto handler vector of `key`, or onto `fallback`: function key leaves default third."""
push_handler!(handlers::Dict{Function, Vector{Int}}, key::Function, fallback::Vector{Int})::Nothing = (push!(get(handlers, key, fallback), 1); nothing)
"""Push onto entry `:a` of `table`, or onto `items` that default closure gives."""
push_default!(table::Dict{Symbol, Vector{Int}}, items::Vector{Int})::Nothing = (push!(get(() -> items, table, :a), 1); nothing)
"""Push onto sample of `groups`: sample with dimensions is new vector."""
push_sample!(groups::Vector{Vector{Int}})::Nothing = (push!(rand(groups, 2), Int[]); nothing)
"""Zero first byte that `take!` gives: bytes can share buffer of `io`."""
take_bytes(io::IOBuffer)::Vector{UInt8} = (bytes = take!(io); bytes[1] = 0x00; bytes)
"""Zero larger of `left` and `right`."""
zero_larger!(left::Box, right::Box)::Nothing = (ifelse(left.value > right.value, left, right).value = 0; nothing)
"""Zero first element of `items`, or of new vector: write reaches `items` only when `flag` holds."""
zero_chosen!(flag::Bool, items::Vector{Int})::Nothing = (ifelse(flag, items, [2])[1] = 0; nothing)
"""Callable counter."""
mutable struct Tally <: Function
    count::Int
end
(tally::Tally)() = tally.count
"""Reset `left` or `right`: choice keeps callable operands."""
reset_either!(flag::Bool, left::Tally, right::Tally)::Nothing = (setfield!(ifelse(flag, left, right), :count, 0); nothing)
"""Callable holder of vectors with indexing."""
struct Shelf <: Function
    items::Vector{Vector{Int}}
end
(shelf::Shelf)() = length(shelf.items)
Base.getindex(shelf::Shelf, index::Int) = shelf.items[index]
"""Push onto first vector of `shelf`: indexing callable object is load."""
stock!(shelf::Shelf)::Nothing = (push!(shelf[1], 7); nothing)
Base.convert(::Type{Box}, holder::Holder) = Box(holder.box.value)
"""Zero box that typed literal converts from `holder`: conversion gives new box."""
zero_converted!(holder::Holder)::Nothing = (Box[holder][1].value = 0; nothing)
Base.promote_rule(::Type{Holder}, ::Type{Box}) = Box
"""Zero first element of literal that promotes `holder` to new box."""
zero_promoted!(holder::Holder, box::Box)::Nothing = ([holder, box][1].value = 0; nothing)
"""Marker type whose literal syntax returns its one vector."""
struct Same end
Base.getindex(::Type{Same}, items::Vector{Int}) = items
"""Push onto `Same[items]`: package literal method is package call."""
push_same!(items::Vector{Int})::Nothing = (push!(Same[items], 2); nothing)
"""Zero `box` through vector literal."""
zero_listed!(box::Box)::Nothing = ([box][1].value = 0; nothing)
"""Zero `box` through typed vector literal."""
zero_typed_listed!(box::Box)::Nothing = (Box[box][1].value = 0; nothing)

# Alias table and constructor.
"""View of first element of `items`."""
first_view(items::Vector{Int}) = view(items, 1:1)
"""Zero first two elements of `items` through view."""
zero_view!(items::Vector{Int})::Nothing = (fill!(view(items, 1:2), 0); nothing)
"""Holder of `box`."""
wrap(box::Box)::Holder = Holder(box)

# Globals.
"""Advance `COUNTER`."""
bump!()::Nothing = (COUNTER[] += 1; nothing)
"""Set `total`."""
set_total!(value::Int)::Nothing = (global total = value; nothing)
"""Read `total`."""
read_total()::Int = total

# Reads.
"""Read scoped level."""
level()::Int = LEVEL[]
"""Read task-local storage."""
task_state()::IdDict{Any, Any} = task_local_storage()
"""Read task-local value under `key`."""
task_value(key::Symbol)::Any = task_local_storage(key)
"""Boxes in order; iteration by generic method."""
struct Countdown
    boxes::Vector{Box}
end
Base.iterate(countdown::Countdown, index::Int = 1) = index > length(countdown.boxes) ? nothing : (countdown.boxes[index], index + 1)
"""Whether `countdown` has no box: generic `isempty` starts iteration."""
finished(countdown::Countdown)::Bool = isempty(countdown)
"""First element of `items`: starts iteration."""
first_of(items::Vector{Int})::Int = first(items)
"""Sum of `items`: consuming function starts iteration."""
total_of(items::Vector{Int})::Int = sum(items)
"""Whether `itr` is empty: `isdone` result can be `missing`, so generic `isempty` may iterate."""
emptiness(itr::Any)::Bool = isempty(itr)

# Compiler effects and call facts.
"""Sum of `x` and `y`."""
add(x::Int, y::Int)::Int = x + y
"""Run writing closure under block claim: claim voids compiler proof of call."""
assumed_foreach!(out::Vector{Int}, items::Vector{Int})::Nothing = Base.@assume_effects :effect_free foreach(item -> push!(out, item), items)
"""Call `f` under false claim: compiler trusts claim at each call."""
Base.@assume_effects :effect_free run_claimed(f::Function) = f()
"""Run writing closure through claimed helper: helper claim voids compiler proof of call."""
claimed_caller!(out::Vector{Int})::Vector{Int} = (run_claimed(() -> push!(out, 1)); out)
"""Call `f` with keyword under false claim."""
Base.@assume_effects :effect_free run_keyword(f::Function; flag::Bool = true) = flag ? f() : nothing
"""Run writing closure through claimed keyword helper: keyword call voids compiler proof."""
keyword_caller!(out::Vector{Int})::Vector{Int} = (run_keyword(() -> push!(out, 1); flag = true); out)
"""Store under block `@assume_effects`: compiler trusts claim."""
assumed_store!(items::Vector{Int})::Vector{Int} = (Base.@assume_effects :effect_free items[1] = 3; items)
"""Address of thread count in Julia library: library tuple stays nested call in IR."""
thread_count_address()::Ptr{Cint} = cglobal((:jl_n_threads, "libjulia-internal"), Cint)
"""Generated method: its `Method` has no `source`."""
@generated generated_double(x::Real) = :(x + x)
"""Store under block claim in generated code: compiler trusts claim, though `Method.source` holds none."""
@generated function generated_store!(items::Vector{Int})
    return quote
        Base.@assume_effects :effect_free items[1] = 3
        items
    end
end
"""Store under block claim in generated branch: compiler infers it, not claim-free fallback."""
function optional_store!(items::Vector{Int})
    if @generated
        return quote
            Base.@assume_effects :effect_free items[1] = 3
            items
        end
    else
        items[1] = 3
        return items
    end
end
"""Call generated store: compiler trusts claim of direct callee."""
generated_caller!(items::Vector{Int})::Vector{Int} = (generated_store!(items); items)
"""Discard length of `items`."""
discard(items::Vector{Int})::Nothing = (length(items); nothing)
"""Discard length of element of unknown type: compiler effects join methods loaded now."""
discard_open(items::Vector{Any})::Nothing = (length(items[1]); nothing)
"""Lowering copies `finally` call, so calls of `abs` outnumber source calls: no exact span, blind spot."""
discard_finally(x::Int)::Int = (
    abs(x); try
        println(x)
    finally
        abs(x)
    end; x
)
"""Computed callee has no name, so mapping cannot place call: blind spot."""
discard_computed(x::Int)::Int = (getfield(Base, :abs)(x); x)

# Loop writes (F48).
"""Repeat each item at end: loop over `items` grows it."""
function loop_push!(items::Vector{Int})::Vector{Int}
    for item in items
        push!(items, item)
    end
    return items
end
"""Delete each key: loop over view of `table`."""
function loop_keys!(table::AbstractDict{Int, Int})::AbstractDict{Int, Int}
    for key in keys(table)
        delete!(table, key)
    end
    return table
end
"""Delete each key of `Dict`: Base deletes while iterating it."""
function loop_dict!(table::Dict{Int, Int})::Dict{Int, Int}
    for key in keys(table)
        delete!(table, key)
    end
    return table
end
"""Replace first element in loop: array keeps its indices."""
function loop_replace!(items::Vector{Int})::Vector{Int}
    for item in items
        items[1] = item
    end
    return items
end
"""Collection in field."""
mutable struct Bin
    items::Vector{Int}
    seen::Int
end
"""Empty items of `bin`."""
clear!(bin::Bin)::Bin = (empty!(bin.items); bin)
"""Grow field while loop iterates it: two loads of one place."""
function loop_field!(bin::Bin)::Bin
    for item in bin.items
        push!(bin.items, item)
    end
    return bin
end
"""Clear holder of iterated field: package call can change field."""
function loop_holder!(bin::Bin)::Bin
    for item in bin.items
        clear!(bin)
    end
    return bin
end
"""Grow holder of iterated element: size change leaves element."""
function loop_outer!(groups::Vector{Vector{Int}})::Vector{Vector{Int}}
    for item in first(groups)
        push!(groups, [item])
    end
    return groups
end
"""Grow element while loop iterates other element: each load can be other object."""
function loop_element!(groups::Vector{Vector{Int}}, i::Int, j::Int)::Vector{Vector{Int}}
    for item in groups[i]
        push!(groups[j], item)
    end
    return groups
end
"""Grow field that name selects while loop iterates it: each load can be other field."""
function loop_named!(bin::Bin, name::Symbol)::Bin
    for item in getfield(bin, name)
        push!(getfield(bin, name), item)
    end
    return bin
end
"""Bin iterates its items and counts each step."""
Base.iterate(bin::Bin, index::Int = 1) = index > length(bin.items) ? nothing : (bin.items[index], index + 1)
"""Count steps in field of iterated object."""
function loop_count!(bin::Bin)::Bin
    for _ in bin
        setfield!(bin, :seen, bin.seen + 1)
    end
    return bin
end
"""Resume iteration from `state`: first step lies off cycle, so loop has no start."""
function loop_resume!(items::Vector{Int}, state::Int)::Vector{Int}
    next = iterate(items, state)
    while next !== nothing
        item, state = next
        push!(items, item)
        next = iterate(items, state)
    end
    return items
end

# Self-alias calls (F50).
"""Multiply into input: `mul!` output must not alias input."""
function alias_mul!(x::Vector{Float64}, matrix::Matrix{Float64})::Vector{Float64}
    LinearAlgebra.mul!(x, matrix, x)
    return x
end
"""Sum into same array: `sum!` fills output with zero first."""
function alias_sum!(x::Vector{Float64})::Vector{Float64}
    sum!(x, x)
    return x
end
"""Sum into array passed through `identity`: `identity` returns its operand."""
function alias_identity!(x::Vector{Float64})::Vector{Float64}
    sum!(x, identity(x))
    return x
end
"""Sum field into same field: two loads give one place."""
function alias_field!(bin::Bin)::Bin
    sum!(bin.items, bin.items)
    return bin
end
"""Remove indices that array itself lists: index operand reads before resize."""
function alias_indices!(x::Vector{Int})::Vector{Int}
    splice!(x, x)
    return x
end
"""Remove indices that view of array lists: index operand reads before resize."""
function alias_index_view!(x::Vector{Int})::Vector{Int}
    splice!(x, view(x, 1:2))
    return x
end
"""Replace front with array itself: `splice!` copies replacement after resize."""
function alias_splice!(x::Vector{Int})::Vector{Int}
    splice!(x, 1:2, x)
    return x
end
"""Submodule that shares name of standard library."""
module Lookalike
    """Square `x` element by element: package `mul!`, not LinearAlgebra one."""
    module LinearAlgebra
        mul!(x::Vector{Float64}, y::Vector{Float64})::Vector{Float64} = (x .*= y)
    end
end
"""Square through package `mul!` in submodule named `LinearAlgebra`: no library table entry."""
function alias_lookalike!(x::Vector{Float64})::Vector{Float64}
    Lookalike.LinearAlgebra.mul!(x, x)
    return x
end
"""Square in place: Base calls `map!(f, A, A)` equivalent of `map!(f, A)`."""
function alias_map!(x::Vector{Float64})::Vector{Float64}
    map!(abs2, x, x)
    return x
end
"""Shift through overlapping views of one array."""
function alias_view!(x::Vector{Float64})::Vector{Float64}
    map!(identity, view(x, 2:3), view(x, 1:2))
    return x
end
"""Scan array into view of itself: view takes place of parent, yet is other object."""
function alias_parent!(x::Vector{Int})::Vector{Int}
    accumulate!(+, view(x, 2:3), x)
    return x
end
"""Copy through overlapping views: `copyto!` unaliases input."""
function alias_copy!(x::Vector{Float64})::Vector{Float64}
    copyto!(view(x, 2:3), view(x, 1:2))
    return x
end
"""Append array to itself: `append!` docstring has no aliasing warning."""
function alias_append!(x::Vector{Int})::Vector{Int}
    append!(x, x)
    return x
end
"""Append view of array to itself: shared memory, but `append!` docstring has no aliasing warning."""
function alias_append_view!(x::Vector{Int})::Vector{Int}
    append!(x, view(x, 1:2))
    return x
end
"""Sum view of other array: no shared memory."""
function alias_other!(x::Vector{Float64}, y::Vector{Float64})::Vector{Float64}
    sum!(x, view(y, 1:2))
    return x
end
"""
    blend!(out, input)

Average `input` into `out`.

$(Base._DOCS_ALIASING_WARNING)
"""
function blend!(out::AbstractVector{Float64}, input::AbstractVector{Float64})::AbstractVector{Float64}
    out .= (out .+ input) ./ 2
    return out
end
"""Blend shifted view: package docstring carries Base aliasing warning."""
function alias_blend!(x::Vector{Float64})::Vector{Float64}
    blend!(view(x, 2:3), view(x, 1:2))
    return x
end
"""Grow `items` after inner loop over it ends: outer loop iterates other collection."""
function loop_after_inner!(groups::Vector{Int}, items::Vector{Int})::Vector{Int}
    total = 0
    for group in groups
        for item in items
            total += item
        end
        push!(items, group + total)
    end
    return items
end
"""Grow `items` in loop over zip of it with itself: view operand appears twice."""
function loop_zipped!(items::Vector{Int})::Vector{Int}
    for (first_item, _) in zip(items, items)
        push!(items, first_item)
    end
    return items
end
"""Grow narrowed argument in loop over it."""
function loop_narrowed!(items::Any)::Any
    if items isa Vector{Int}
        for item in items
            push!(items, item)
        end
    end
    return items
end
@eval begin
    """Grow one literal in loop over other: global state that no binding names is no one object."""
    function loop_literal!()::Nothing
        for item in $(Int[1])
            push!($(Int[2]), item)
        end
        return nothing
    end
end

# Stateful reuse (F51): iterator started twice, or escaping after start.
"""Loop after `first`: second start of argument any iterator can fill."""
function reuse_first(itr::Any)::Any
    head = first(itr)
    for item in itr
        head = item
    end
    return head
end
"""Loop after `isempty`: generic `isempty` is one of many methods, so start is possible."""
function reuse_isempty(itr::Any)::Int
    isempty(itr) && return 0
    count = 0
    for _ in itr
        count += 1
    end
    return count
end
"""`first` inside loop: start runs again on each pass."""
function reuse_loop(itr::Any, n::Int)::Int
    found = 0
    for _ in 1:n
        found += first(itr)
    end
    return found
end
"""Zip of iterator with itself: one call starts it twice."""
reuse_zip(itr::Any)::Int = count(pair -> pair[1] == pair[2], zip(itr, itr))
"""Returned zip of iterator with itself: caller that consumes it starts iterator twice."""
reuse_zip_returned(itr::Any)::Any = zip(itr, itr)
"""`isempty` of zip iterates it when `isdone` of part gives `missing`: both parts start."""
reuse_zip_empty(itr::Any)::Bool = isempty(zip(itr, itr))
"""Twelve nested `zip(z, z)`: iterator starts twice, and joint starts stay few."""
function reuse_zip_chain(itr::Any)::Any
    z = zip(itr, itr)
    z = zip(z, z)
    z = zip(z, z)
    z = zip(z, z)
    z = zip(z, z)
    z = zip(z, z)
    z = zip(z, z)
    z = zip(z, z)
    z = zip(z, z)
    z = zip(z, z)
    z = zip(z, z)
    z = zip(z, z)
    return z
end
"""Load of same element on each loop pass can give same iterator again."""
function reuse_reload(groups::Vector{Any}, n::Int)::Int
    total = 0
    for _ in 1:n
        itr = groups[1]
        total += sum(itr)
    end
    return total
end
"""Zip result that code never consumes iterates nothing."""
kept_zip_type(itr::Any)::Type = typeof(zip(itr, itr))
"""Returned tuple holds fresh value twice, never iterator."""
function kept_shared(make::Function, itr::Any)::Tuple{Any, Any}
    part = make()
    sum(itr)
    return (part, part)
end
"""Discarded zip of iterator with itself iterates nothing."""
function kept_zip(itr::Any)::Int
    zip(itr, itr)
    return sum(itr)
end
"""Return iterator with its first element: caller gets started iterator."""
reuse_return(itr::Any)::Tuple{Any, Any} = (first(itr), itr)
"""Asserted argument is argument itself: loop after `first` of it starts argument again."""
function reuse_asserted(itr::Any)::Any
    head = first(itr::Any)
    for x in itr
        head = x
    end
    return head
end
"""Hand argument to package function, then loop over it."""
function reuse_handed(itr::Any)::Int
    reuse_return(itr)
    return sum(itr)
end
"""Store tuple that holds iterator, then loop over iterator."""
function reuse_stored(box::Vector{Any}, itr::Any)::Int
    push!(box, (itr, 1))
    return sum(itr)
end
"""Fresh iterator in returned tuple after `first`: caller gets started iterator."""
function reuse_fresh(make::Function)::Tuple{Any, Any}
    itr = make()
    head = first(itr)
    return (head, itr)
end
"""Union of stateful and multi-pass iterator: loop after `first` depends on branch."""
function reuse_mixed(io::IO, flag::Bool)::Int
    itr = flag ? eachline(io) : readlines(io)
    head = first(itr)
    return count(line -> line != head, itr)
end
"""Each element starts twice in one pass of outer loop."""
function reuse_inner(groups::Any)::Int
    total = 0
    for group in groups
        head = first(group)
        for item in group
            total += item - head
        end
    end
    return total
end
"""`isempty` on `eachline` result: `isdone` checks end of stream without reading line."""
function kept_lines(io::IO)::Int
    lines = eachline(io)
    isempty(lines) && return 0
    return count(_ -> true, lines)
end
"""Dictionary from fresh iterator: constructor holds elements, so iterator does not escape."""
function kept_collected(make::Function)::Dict{Any, Int}
    items = make()
    isempty(items) && return Dict{Any, Int}()
    return Dict{Any, Int}(item => 1 for item in items)
end
"""Header line, then other lines: restart of stateful kind is deliberate."""
function kept_peeled(io::IO)::Int
    lines = eachline(io)
    header = first(lines)
    return count(line -> line != header, lines)
end
"""Destructured elements: each pass starts new element."""
function kept_destructured(entries::Any)::Int
    total = 0
    for (a, b) in entries
        total += a + b
    end
    return total
end
"""Nested loop: inner loop starts new group on each outer pass."""
function kept_nested(groups::Any)::Int
    total = 0
    for group in groups, item in group
        total += item
    end
    return total
end
"""Vector after `isempty`: arrays start from first element each time."""
kept_vector(items::Vector{Int})::Int = isempty(items) ? 0 : sum(items)
"""Destructured and returned `iterate` result: protocol makes it tuple, though inference gives `Any`."""
function kept_protocol(itr::Any)::Any
    next = iterate(itr)
    isnothing(next) && return nothing
    value, _ = next
    return (value, next)
end
"""Iterator struct of any parameters."""
struct Bag{T}
    items::Vector{T}
end
Base.iterate(bag::Bag, index::Int = 1) = index > length(bag.items) ? nothing : (bag.items[index], index + 1)
"""Element of `Vector{Bag}`: field `Vector{T}` holds parameter, so `iterate` body decides kind. Blind spot, no finding."""
function kept_family(bags::Vector{Bag})::Int
    bag = bags[1]
    return isempty(bag) ? 0 : count(_ -> true, bag)
end
"""Iterator that passes iteration to its field: kind follows field type."""
struct Relay{T}
    inner::T
end
Base.iterate(relay::Relay, state...) = iterate(relay.inner, state...)
"""Element of `Vector{Relay}` can hold stateful iterator: second `first` restarts it."""
function reuse_relay(relays::Vector{Relay})::Tuple{Any, Any}
    relay = relays[1]
    return (first(relay), first(relay))
end
"""`Pair` iterates its two fields whatever their types: one kind."""
function kept_pair(pairs::Vector{Pair})::Tuple{Any, Any, Any, Any}
    pair = pairs[1]
    first_key, first_value = pair
    second_key, second_value = pair
    return (first_key, first_value, second_key, second_value)
end
"""`enumerate` of struct family element: wrapper bound has one kind, so wrapper has one kind."""
function kept_enumerated(bags::Vector{Bag})::Int
    bag = bags[1]
    reuse_return(bag)
    return count(_ -> true, enumerate(bag))
end
"""Abstract type with own `first`."""
abstract type Shape end
"""Only shape."""
struct Square <: Shape end
Base.first(::Shape)::Int = 0
"""Package `first` serves abstract shape: its body decides start, so pair is blind spot."""
function kept_dispatched(shapes::Vector{Shape})::Int
    shape = shapes[1]
    return first(shape) + first(shape)
end
"""Abstract iterator with own `first` and `iterate`."""
abstract type Counter end
"""Only counter."""
struct Once <: Counter end
Base.first(::Counter)::Int = 0
Base.iterate(::Counter, state::Int = 0)::Union{Nothing, Tuple{Int, Int}} = state < 1 ? (state, state + 1) : nothing
"""Package `first` gives blind spot; two `iterate` starts after it still pair."""
function reuse_after_dispatched(counters::Vector{Counter})::Tuple{Any, Any, Any}
    counter = counters[1]
    return (first(counter), iterate(counter), iterate(counter))
end
"""Abstract source; generic `first` serves sources other than `Fixed`."""
abstract type Source end
"""Source with own `first`, which iterates nothing."""
struct Fixed <: Source end
Base.first(::Fixed)::Int = 0
"""Abstract package range: its own `first` cannot take `Iterators.Stateful`, so generic `first` stays `definite`."""
abstract type Interval end
Base.first(::Interval)::Int = 0
"""Generic `first` starts only sources other than `Fixed`: pair is `possible`."""
function reuse_mixed_dispatch(sources::Vector{Source})::Tuple{Any, Any}
    source = sources[1]
    return (first(source), first(source))
end
"""Abstract iterator whose own `isdone` gives `missing`: generic `isempty` iterates it."""
abstract type Drain end
"""Only drain."""
struct Sink <: Drain end
Base.isdone(::Drain)::Missing = missing
Base.iterate(::Drain, state::Int = 0)::Union{Nothing, Tuple{Int, Int}} = state < 1 ? (state, state + 1) : nothing
"""`isempty` starts drain through package `isdone`; `iterate` starts it again."""
function reuse_isdone(drains::Vector{Drain})::Any
    drain = drains[1]
    isempty(drain) && return nothing
    return iterate(drain)
end
"""Function with own `map` method that takes any collection and iterates nothing."""
marker(x::Any)::Any = x
Base.map(::typeof(marker), ::Any)::Tuple{} = ()
"""Package `map` takes `Any` collection, yet its body decides start: pair is blind spot."""
function kept_marked(sources::Vector{Source})::Tuple{Tuple{}, Tuple{}}
    source = sources[1]
    return (map(marker, source), map(marker, source))
end
"""Struct whose second field takes any relay, after field of number relays: kind follows second field."""
struct Twin{A <: Relay{<:Number}, B <: Relay}
    numbers::A
    relay::B
end
"""Relay whose field parameter is bounded by other parameter: bound resolves through it."""
struct Chain{S, T <: S}
    inner::T
end
"""Struct of two parameter fields: nested type that shares bounds tests classification cost."""
struct Duo{A, B}
    first::A
    second::B
end
"""Field that struct declares as named tuple: multi-pass whatever its parameters."""
struct Named{K, V}
    items::NamedTuple{K, V}
end
"""Named tuple field escapes to package function, then iteration starts."""
function kept_declared(named::Named)::Int
    reuse_return(named.items)
    return count(_ -> true, named.items)
end
"""Loop that threads `iterate` state: one start."""
function kept_state(itr::Any)::Int
    count, next = 0, iterate(itr)
    while !isnothing(next)
        count += 1
        next = iterate(itr, next[2])
    end
    return count
end
"""Take element with `popfirst!`, then loop: write, not start."""
function kept_popped(lines::Iterators.Stateful)::Int
    popfirst!(lines)
    return count(_ -> true, lines)
end
"""Starts on separate branches: one start per path."""
kept_branches(itr::Any, flag::Bool)::Any = flag ? first(itr) : collect(itr)
"""Package iterator type: concrete type outside stateful table."""
kept_countdown(countdown::Countdown)::Int = isempty(countdown) ? 0 : length(collect(countdown))

end
