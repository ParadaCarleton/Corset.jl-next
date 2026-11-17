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

end
