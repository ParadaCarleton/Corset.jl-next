# runic: off
module BangConventionPositive

# Writes argument without `!`.
normalize(v::Vector{Float64}) = (v ./= sum(v); v)

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

end
