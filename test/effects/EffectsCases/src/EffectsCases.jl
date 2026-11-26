"""Effects engine fixtures: one method per transfer function, origin kind and path depth."""
module EffectsCases

import Random

mutable struct Box
    value::Int
end

mutable struct Holder
    box::Box
end

mutable struct Chain
    next::Holder
end

mutable struct Wrapper
    chain::Chain
end

mutable struct Counter
    @atomic count::Int
end

mutable struct Loose
    content::Any
end

const COUNTER = Ref(0)

global total::Int = 0

set_value!(box::Box, value::Int)::Nothing = (box.value = value; nothing)

set_inner!(holder::Holder, value::Int)::Nothing = (holder.box.value = value; nothing)

set_deep!(chain::Chain, value::Int)::Nothing = (chain.next.box.value = value; nothing)

set_deeper!(wrapper::Wrapper, value::Int)::Nothing = (wrapper.chain.next.box.value = value; nothing)

fill_first!(values::Vector{Int})::Nothing = (values[1] = 0; nothing)

first_value(values::Vector{Int})::Int = values[1]

read_box(box::Box)::Int = box.value

add(x::Int, y::Int)::Int = x + y

bump!()::Nothing = (COUNTER[] += 1; nothing)

set_total!(value::Int)::Nothing = (global total = value; nothing)

read_total()::Int = total

function fresh_sum(x::Int)::Int
    box = Box(x)
    box.value += 1
    return box.value
end

push_box!(boxes::Vector{Box}, box::Box)::Nothing = (push!(boxes, box); nothing)

first_view(values::Vector{Int}) = view(values, 1:2)

zero_view!(values::Vector{Int})::Nothing = (first_view(values)[1] = 0; nothing)

counter_ref()::Base.RefValue{Int} = COUNTER

reset_counter!()::Nothing = (counter_ref()[] = 0; nothing)

function countdown!(box::Box, n::Int)::Nothing
    n <= 0 && return nothing
    box.value = n
    return countdown!(box, n - 1)
end

ping!(box::Box, n::Int)::Nothing = n <= 0 ? nothing : pong!(box, n - 1)

pong!(box::Box, n::Int)::Nothing = (box.value = n; ping!(box, n))

fail(x::Int)::Int = error("fail $x")

increment!(counter::Counter)::Nothing = (@atomic counter.count += 1; nothing)

swap_count!(counter::Counter, count::Int)::Int = @atomicswap counter.count = count

touch!(box::Box)::Nothing = (box.value = 0; nothing)
touch!(values::Vector{Int})::Nothing = (values[1] = 0; nothing)
touch!(text::String)::Nothing = nothing

poke!(loose::Loose)::Nothing = (touch!(loose.content); nothing)

store_pointer!(values::Vector{Int})::Nothing = (GC.@preserve values unsafe_store!(pointer(values), 1); nothing)

load_pointer(values::Vector{Int})::Int = GC.@preserve values unsafe_load(pointer(values))

function swap_first!(values::Vector{Int}, value::Int)::Nothing
    values[1], values[2] = value, values[1]
    return nothing
end

copy_box(box::Box)::Box = Box(box.value)

boxes_of(box::Box)::Vector{Box} = [box]

const NEST = Ref(Ref(Ref([1])))

bump_nest!()::Nothing = (NEST[][][][1] = 2; nothing)

call_nest!()::Nothing = bump_nest!()

call_deeper!(wrapper::Wrapper)::Nothing = set_deeper!(wrapper, 1)

"""Recursive list node: path into `next` repeats its type, so it collapses to `deep`."""
mutable struct Link
    value::Int
    next::Link
end

relink!(link::Link)::Nothing = (link.next.next = link; nothing)

"""Recursive node that holds `IO`: kind below collapsed path comes from written object type."""
mutable struct IOLink
    io::IOBuffer
    next::IOLink
end

relink_io!(link::IOLink)::Nothing = (link.next.next = link; nothing)

rewind_io!(link::IOLink)::Nothing = (seekstart(link.next.io); nothing)

"""Raw write into `IO` memory below collapsed path: exempt kind lacks proof, so write counts as memory write."""
clear_io!(link::IOLink)::Nothing = (fill!(link.next.io.data, 0x00); nothing)

read_module()::Int = getproperty(EffectsCases, :total)

stamp!(cell::Base.RefValue{Int})::Nothing = (cell[] = 1; nothing)
stamp!(cell::Base.RefValue{Float64})::Nothing = (cell[] = 1.0; nothing)

stamp_either!(cell::Union{Base.RefValue{Int}, Base.RefValue{Float64}})::Nothing = stamp!(cell)

measure(cell::Base.RefValue{Int})::Float64 = cell[]
measure(cell::Base.RefValue{Float64})::Float64 = cell[]

measure_either(cell::Union{Base.RefValue{Int}, Base.RefValue{Float64}})::Float64 = measure(cell)

copy_into!(target::Vector{Int}, source::Vector{Int})::Nothing = (copyto!(target, source); nothing)

copy_boxes!(target::Vector{Box}, source::Vector{Box})::Nothing = (copyto!(target, source); target[1].value = 0; nothing)

remember!(table::IdDict{Int, Box}, box::Box)::Nothing = (table[1] = box; table[1].value = 0; nothing)

call_on(f::Any, box::Box) = f(box)

# Provenance: open dispatch whose open types code wrote, Corset chose, or code opted out of.
reset!(box::Box)::Nothing = (box.value = 0; nothing)
reset!(counter::Counter)::Nothing = (@atomic counter.count = 0; nothing)
reset!(cell::Base.RefValue{Int})::Nothing = (cell[] = 0; nothing)
reset!(values::Vector{Int})::Nothing = (values[1] = 0; nothing)

reset_first!(values::AbstractVector)::Nothing = (reset!(values[1]); nothing)

reset_any!(target::Any)::Nothing = (reset!(target); nothing)

function reset_typed!(target::T)::Nothing where {T}
    reset!(target)
    return nothing
end

reset_slot!(slot::Base.RefValue{Any})::Nothing = (reset!(slot[]); nothing)

reset_default!(target::Any = nothing)::Nothing = (reset!(target); nothing)

# Untyped method: only unit call reaches, with caller types; `Any` element type is code there.
reset_items!(count, items) = (reset!(items[1]); count)
fill_any!(count::Integer, box::Box)::Nothing = (reset_items!(count, Any[box]); nothing)

# More `IO` methods than join takes: call on `IO` stays open.
send!(io::IOBuffer, box::Box)::Nothing = (box.value = 0; nothing)
send!(io::IOStream, box::Box)::Nothing = (box.value = 0; nothing)
send!(io::Base.DevNull, box::Box)::Nothing = nothing
send!(io::Base.TTY, box::Box)::Nothing = nothing

emit!(io::IO, box::Box)::Nothing = (send!(io, box); nothing)

function emit_typed!(io::IO, target::T)::Nothing where {T}
    send!(io, target)
    return nothing
end

forward!(io, box) = (send!(io, box); nothing)

emit_through!(io::IO, box::Box)::Nothing = (forward!(io, box); nothing)

peer(io::IOBuffer)::IO = io
peer(io::IOStream)::IO = io
peer(io::Base.DevNull)::IO = io
peer(io::Base.TTY)::IO = io

emit_peer!(io::IO, box::Box)::Nothing = (send!(peer(io), box); nothing)

apply_to!(f::Function, box::Box)::Nothing = (f(box); nothing)

# Callback records: callable that holds caller object writes where caller made it.
struct Setter
    box::Box
end

(setter::Setter)(value::Int)::Nothing = (setter.box.value = value; nothing)

# Tuple `foreach` wraps closure in `foldl` reducers: path from reducer to box has 3 steps.
fill_pair!(box::Box)::Nothing = foreach(value -> (box.value = value), (1, 2))

push_pair!(sink::Vector{Int})::Nothing = foreach(Base.Fix1(push!, sink), (1, 2))

set_pair!(box::Box)::Nothing = foreach(Setter(box), (1, 2))

# Root unit with callable from caller: no caller resolves record, so root does.
call_setter!(setter::Setter, value::Int)::Nothing = foreach(setter, (value, value))

struct Countdown
    box::Box
end

(countdown::Countdown)(count::Int)::Nothing = count <= 0 ? nothing : (countdown.box.value = count; countdown(count - 1))

count_down!(box::Box)::Nothing = Countdown(box)(3)

struct Relay
    setter::Setter
end

(relay::Relay)(value::Int)::Nothing = (relay.setter(value); nothing)

act_either!(action::Union{Setter, Relay}, value::Int)::Nothing = (action(value); nothing)

# Call cycle: `restart!` resolves record of `Ticker` call, member of same cycle. `Ticker` call writes `second` only after
# its summary takes write of `first` from `restart!`, which callees-first order solves after it.
struct Ticker
    box::Box
end

(ticker::Ticker)(count::Int)::Nothing = count <= 0 ? nothing : restart!(ticker.box, Box(0), count - 1)

restart!(first::Box, second::Box, count::Int)::Nothing = (first.value = count; run_ticker(Ticker(second), count))

run_ticker(ticker::Ticker, count::Int)::Nothing = ticker(count)

# Callable grows in round 2: loop phi takes fresh `Setter`, so call resolves here and record of round 1 goes.
function pick_setter!(setter::Setter, value::Int)::Nothing
    current = setter
    for _ in 1:2
        current(value)
        current = Setter(Box(0))
    end
    return nothing
end

# Compiler effects: shortcut for instance compiler proves empty. Claims outside Base turn it off, false claims included.
const SCOPE = Base.ScopedValues.ScopedValue{Int}(1)

read_scope()::Int = SCOPE[]

# Engine reads `Memory`; compiler proves read of its constant length touches nothing, so unit verdict keeps no read.
memory_length(memory::Memory{Int})::Int = getfield(memory, :length)

same_box(box::Box)::Box = box

Base.@assume_effects :effect_free :inaccessiblememonly :notaskstate :nothrow :terminates_globally claim_bump!()::Nothing = (COUNTER[] += 1; nothing)

call_claim_bump!()::Nothing = claim_bump!()

Base.@assume_effects :effect_free :nothrow :terminates_globally claim_set!(box::Box)::Nothing = (box.value = 1; nothing)

drop_claim_set!(box::Box)::Nothing = (claim_set!(box); nothing)

function block_claim!(box::Box)::Nothing
    Base.@assume_effects :effect_free :nothrow begin
        box.value = 2
    end
    return nothing
end

drop_block_claim!(box::Box)::Nothing = (block_claim!(box); nothing)

@generated generated_next(x::Int) = :(x + 1)

call_generated(x::Int)::Int = generated_next(x)

# Stand-in cuts: stand-in decides type test, so write in branch is dead on stand-ins only.
maybe_bump!(x::Real)::Nothing = (x isa BigFloat && (COUNTER[] += 1); nothing)

call_maybe_bump!(x::Real)::Nothing = maybe_bump!(x)

set_maybe_bump!(box::Box, x::Real)::Nothing = (box.value = 1; maybe_bump!(x))

# Declared type decides test too: branch is dead on every signature, so it is no cut.
integer_bump!(x::Integer)::Nothing = (x isa AbstractFloat && (COUNTER[] += 1); nothing)

# Declared signature gives no generated code, so it cannot clear dead call.
@generated generated_bump!(x::Real) = :(x isa BigFloat && (COUNTER[] += 1); nothing)

# No method takes array stand-in: call never returns on stand-ins only, and no dead statement follows it.
zero_dense!(values::Vector{Int})::Nothing = (values[1] = 0; nothing)

maybe_zero!(values::AbstractVector{Int}, flag::Bool)::Nothing = (flag && zero_dense!(values); nothing)

# Untyped helpers stay outside units: library cut check finds `pointer`, which fails on stand-in only.
poke_at!(values, index) = (index > 0 && unsafe_store!(pointer(values), index); nothing)

poke_some!(values::AbstractVector{Int}, index::Int)::Nothing = poke_at!(values, index)

# Helper catches failing call, so compiler proves it `nothrow`; method with `try` still gets cut check.
function poke_caught_at!(values, index)
    try
        index > 0 && unsafe_store!(pointer(values), index)
    catch
    end
    return nothing
end

poke_quietly!(values::AbstractVector{Int}, index::Int)::Nothing = poke_caught_at!(values, index)

# Call fails on model types too: no cut. `reject` returns for `Int`, so it is no throw helper.
reject(values::AbstractVector)::Nothing = error("vector")
reject(count::Int)::Int = count

refuse(values) = (reject(values); nothing)

# Stand-in dispatches to throwing method; model type dispatches to writing one.
fill_dense!(values::AbstractVector{Int})::Nothing = error("dense only")
fill_dense!(values::Vector{Int})::Nothing = (values[1] = 0; nothing)

maybe_fill!(values::AbstractVector{Int}, flag::Bool)::Nothing = (flag && fill_dense!(values); nothing)

# Optional generator: declared signature takes fallback code, whose statements differ from generated ones.
function fallback_bump!(x::Real)
    if @generated
        return :(x isa BigFloat && (COUNTER[] += 1); nothing)
    else
        identity(x)
        x isa BigFloat && (COUNTER[] += 1)
        return nothing
    end
end

# Optional generator runs on declared signature too, with other code there: its statements match no stand-in statement.
function generated_shift!(x::Real)
    if @generated
        return x === Real ? :(nothing) : :(x isa BigFloat && (COUNTER[] += 1); nothing)
    else
        x isa BigFloat && (COUNTER[] += 1)
        return nothing
    end
end

# Generated code differs per signature: model code cannot clear call that fails on stand-in.
@generated generated_poke(values::AbstractVector{Int}, flag::Bool) = values <: Vector ? :(nothing) : :(flag && pointer(values); nothing)

# Conversion fails on model type too: failing-call fact, no cut.
maybe_convert(values::AbstractVector{Int}, flag::Bool)::Nothing = (flag && convert(Int, values); nothing)

# `error` throws on every signature: no cut.
check_nonempty(values::AbstractVector{Int})::Nothing = (isempty(values) && error("empty"); nothing)

# Open stand-in element: `oneunit` of element type fails on no stand-in, so loop write stays analyzed.
function fill_units!(values::AbstractVector)::Nothing
    unit_value = oneunit(eltype(values))
    for index in eachindex(values)
        values[index] = unit_value
    end
    return nothing
end

# Holder of lock: lock write lands on field place.
struct Guard
    lock::ReentrantLock
    items::Vector{Int}
end

# Acquire without release: definite lock write.
grab_guard!(guard::Guard)::Nothing = (lock(guard.lock); nothing)

# Store throws while method holds lock: release is skipped.
function guarded_set!(guard::Guard, value::Int)::Nothing
    lock(guard.lock)
    guard.items[1] = value
    unlock(guard.lock)
    return nothing
end

# Two stores throw while method holds lock: F98 fact names first.
function guarded_pair_set!(guard::Guard, value::Int)::Nothing
    lock(guard.lock)
    guard.items[1] = value
    guard.items[2] = value
    unlock(guard.lock)
    return nothing
end

# Callee takes hold: acquire span is call in caller.
function grab_then_set!(guard::Guard, value::Int)::Nothing
    grab_guard!(guard)
    guard.items[1] = value
    unlock(guard.lock)
    return nothing
end

# Release in `finally`: balanced.
safe_set!(guard::Guard, value::Int)::Nothing = (@lock guard.lock (guard.items[1] = value); nothing)

# Lock on one branch: possible lock write.
maybe_grab!(guard::Guard, flag::Bool)::Nothing = (flag && lock(guard.lock); nothing)

# `trylock` result decides hold: blind lock write.
try_grab!(guard::Guard)::Bool = trylock(guard.lock)

# Store throws while hold is blind: blind spot.
function try_set!(guard::Guard, value::Int)::Nothing
    trylock(guard.lock)
    guard.items[1] = value
    return nothing
end

# Holder whose lock field type is open.
struct LooseGuard
    lock::Any
end

# Only method of `take_lock!`: call on open field resolves to it.
take_lock!(lock_object::ReentrantLock)::Nothing = (lock(lock_object); nothing)

# Lock of field without lock type: path kind is memory.
loose_grab!(guard::LooseGuard)::Nothing = take_lock!(guard.lock)

# Lock that task storage holds: object outside every caller place.
lock_stored()::Nothing = (lock(task_local_storage(:lock)::ReentrantLock); nothing)

# Call facts: discarded calls with and without effect, call that may throw, foreign call, used result.
function drop_calls!(values::Vector{Int}, text::String)::Int
    abs(length(values))
    push!(values, 1)
    parse(Int, text)
    ccall(:strlen, Csize_t, (Cstring,), text)
    count = length(values)
    return count
end

# Call facts: builtin, open call and call that no method matches.
function odd_calls(f::Any, flag::Bool, text::String)::Nothing
    Core.ifelse(flag, 1, 2)
    f(text)
    flag && no_text_method(text)
    return nothing
end

# Call facts: constant call result in comparison, and discarded constant call.
function constant_calls(byte::UInt8)::Bool
    UInt8('a')
    return byte == UInt8('\t')
end

# Only method of `no_text_method`: `String` argument matches none.
no_text_method(value::Int)::Int = value

# Iteration starts: loop starts its argument.
function loop_sum(items::Vector{Int})::Int
    total = 0
    for item in items
        total += item
    end
    return total
end

# Holder of iterated vector.
struct ItemHolder
    items::Vector{Int}
end

# Start through callee summary.
holder_sum(holder::ItemHolder)::Int = loop_sum(holder.items)

# Start through Base contract: `first` and destructuring on open type.
first_any(itr::Any) = first(itr)
pair_head(itr::Any) = ((head, _) = itr; head)

# No start: `iterate` with state, and own `isempty` method of `Vector`.
next_item(items::Vector{Int}) = iterate(items, 2)
no_items(items::Vector{Int})::Bool = isempty(items)

# Call that no method matches starts nothing.
dead_start(flag::Bool) = flag ? iterate(nothing) : nothing

# Callee returns two vectors; caller merges them, so write through second is blind spot (`alias`).
@noinline twin_boxes() = (Box[], Box[])
twin_write!(box::Box) = (pair = twin_boxes(); push!(pair[1], box); pair[2][1].value = 0; nothing)

# Caller passes default RNG to RNG argument: draw reads `Task` state, yet method draws from its argument.
# Stand-in for `values` makes each `*_default` call a unit with `TaskLocalRNG` argument.
draw_from(rng::Random.AbstractRNG, values::AbstractVector)::Float64 = rand(rng) * length(values)
draw_default(values::AbstractVector)::Float64 = draw_from(Random.default_rng(), values)
draw_both(rng::Random.AbstractRNG, values::AbstractVector)::Float64 = (rand(rng) + rand()) * length(values)
draw_both_default(values::AbstractVector)::Float64 = draw_both(Random.default_rng(), values)
draw_each(rng::Random.AbstractRNG, values::AbstractVector)::Vector{Float64} = map(_ -> rand(rng), 1:length(values))
draw_each_default(values::AbstractVector)::Vector{Float64} = draw_each(Random.default_rng(), values)
# Closure captures default RNG beside unused RNG argument: inference folds both closures to same constant.
draw_captured(rng::Random.AbstractRNG, values::AbstractVector)::Vector{Float64} = (other = Random.default_rng(); map(_ -> rand(other), 1:length(values)))
draw_captured_default(values::AbstractVector)::Vector{Float64} = draw_captured(Random.default_rng(), values)
# Declared `TaskLocalRNG`: method chose default RNG itself, so caller cannot pass own RNG.
draw_task(rng::Random.TaskLocalRNG, values::AbstractVector)::Float64 = rand(rng) * length(values)

end
