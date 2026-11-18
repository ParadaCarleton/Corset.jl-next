"""Effects engine fixtures: one method per transfer function, origin kind and path depth."""
module EffectsCases

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

end
