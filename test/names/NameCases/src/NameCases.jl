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
"""Discard length of `items`."""
discard(items::Vector{Int})::Nothing = (length(items); nothing)

end
