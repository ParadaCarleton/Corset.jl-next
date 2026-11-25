# runic: off
module BangConventionPositive

using Random: AbstractRNG

# Writes argument without `!`.
normalize(v::Vector{Float64}) = (v ./= sum(v); v)

# Immutable first operand cannot change: `shift!` writes `x`.
struct Shift
    by::Float64
end
shift!(shift::Shift, x::Vector{Float64}) = (x .+= shift.by; x)
shifted(x::Vector{Float64}) = shift!(Shift(1.0), x)

# `.=` into indexed argument writes it: view for range, element for scalar index.
zero_head(v::Vector{Float64}) = (v[1:2] .= 0.0; v)
zero_first(rows::Vector{Vector{Float64}}) = (rows[1] .= 0.0; rows)

# Helper named like `rand!` outside Distributions writes its first operand, RNG or not.
_rand!(state::Base.RefValue{Int}, samples::Vector{Int}) = (state[] += sum(samples); state)
update(state::Base.RefValue{Int}, samples::Vector{Int}) = _rand!(state, samples)
_rand!(rng::AbstractRNG, state::Base.RefValue{Int}, samples::Vector{Int}) = (state[] += rand(rng, samples); state)
update_with(rng::AbstractRNG, state::Base.RefValue{Int}, samples::Vector{Int}) = _rand!(rng, state, samples)

# Writes package global that other method reads.
const TOTAL = Ref(0)
record(x::Int) = (TOTAL[] += x; nothing)
total() = TOTAL[]

# Call of `!` function on argument writes it too.
append_one(items::Vector{Int}) = (push!(items, 1); items)

# Method of Base function that promises no write.
struct Counter
    hits::Vector{Int}
end
Base.length(counter::Counter) = (push!(counter.hits, 1); length(counter.hits))

# Method of Base IO function may write its stream only.
mutable struct Item
    shown::Int
end
Base.show(io::IO, item::Item) = (item.shown += 1; print(io, "Item"))

# Base IO function on type that is not `IO`: callers see no write.
mutable struct Resource
    open::Bool
end
Base.close(resource::Resource) = (resource.open = false; nothing)

# `!` function returns new value and writes nothing.
struct Point
    x::Float64
end
scale!(point::Point, factor::Float64) = Point(point.x * factor)

# Method of Base `!` function returns new value and writes nothing.
Base.empty!(point::Point) = Point(0.0)

# `!!` call on mutable operand writes it, so caller writes it too.
mutable struct Tally
    count::Int
end
tally!!(tally::Tally, x::Int) = (tally.count += x; tally)
counted(tally::Tally) = tally!!(tally, 1)

end
