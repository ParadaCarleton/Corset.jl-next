# runic: off
function squares(xs::Vector{Float64})
    out = Float64[]
    for x in xs
        push!(out, x^2)
    end
    return out
end

function evens(n::Int)
    found = Int[i for i in 1:n if iseven(i)]
    return found
end

function positives(xs::Vector{Int})
    kept = Int[x for x in xs if x > 0]
    return kept
end

function labels(pairs::Vector{Pair{Symbol, Int}})
    names::Vector{Any} = []
    for (name, count) in pairs
        push!(names, name => count)
    end
    return names
end

function scaled(xs::AbstractVector{T}, factor::T) where {T <: Real}
    result = Vector{T}(undef, 0)
    for x in xs
        push!(result, factor * x)
    end
    return result
end

struct Point
    x::Int
end

function points(n::Int)
    made = Point[Point(i) for i = 1:2:n]
    return made
end

function noted(xs::Vector{Int})
    out = Int[]
    for x in xs
        # double each item
        push!(out, 2x)
    end
    return out
end

function shifted(xs::Vector{Int}, offset::Int)
    offset = abs(offset)
    out = Int[]
    for x in xs
        push!(out, x + offset)
    end
    return out
end

function lengths(words::Vector{String})
    out = Int[]
    for word in words
        push!(out, word |> length)
    end
    return out
end

function flattened(grid::Matrix{Int})
    out = Int[]
    for cell in grid
        push!(out, cell + 1)
    end
    return out
end

function sorted_squares(xs::Vector{Int})
    xs = sort(xs)
    out = Int[]
    for x in xs
        push!(out, x^2)
    end
    return out
end

function tagged(; tags::Vector{String} = String[])
    out = Symbol[]
    for tag in tags
        push!(out, Symbol(tag))
    end
    return out
end

function table(n::Int)
    rows = Vector{Int}[]
    for i in 1:n
        row = Int[i * j for j in 1:n]
        push!(rows, row)
    end
    return rows
end

function doubled(xs::Vector{T}) where {T}
    out = T[]
    for x in xs
        push!(out, 2 * x)
    end
    return out
end

function anything(xs::Vector{Int})
    out = Any[string(x) for x in xs if isodd(x)]
    return out
end

const LIMIT = 3
counts = Int[]
for i in 1:LIMIT
    push!(counts, i)
end

function observed(xs::Vector{Int})
    size_now() = length(out)
    out = Int[]
    for x in xs
        push!(out, size_now() + x)
    end
    return out
end

function guarded_divide(xs::Vector{Int})
    out = [9]
    try
        out = Int[]
        for x in xs
            push!(out, div(1, x))
        end
    catch
    end
    return out
end

function nested(groups::Vector{Vector{Int}})
    return map(groups) do group
        out = Int[]
        for x in group
            push!(out, x + 1)
        end
        out
    end
end

# Range no call can resize: comprehension matches loop.
function steps(span::UnitRange{Int})
    out = Int[(2i) for i in span]
    return out
end

# `convert` in `push!` can run package method that resizes `items`; comprehension keeps shape of untyped source.
function wrapped(items)
    out = Tuple{Int}[]
    for item in items
        push!(out, (item,))
    end
    return out
end

# `BigInt` bound can change in place, and range over it changes length: fix is manual.
function upto(n::Integer)
    out = Int[]
    for i in 1:n
        push!(out, 2i)
    end
    return out
end

# Range type parameter must name bits type itself: `Rational{BigInt}` holds mutable bound.
function spanned(span::UnitRange{Rational{BigInt}})
    out = Rational{BigInt}[]
    for i in span
        push!(out, 2i)
    end
    return out
end

# Integer literal past `Int128` makes mutable `BigInt` bound.
function huge()
    out = BigInt[]
    for i in 1:170141183460469231731687303715884105728
        push!(out, 2i)
    end
    return out
end

# Code can read global by computed name, which no name index sees: fix for global is manual.
seen_count() = length(getglobal(@__MODULE__, Symbol("seen")))
seen = Int[]
for i in 1:4
    iseven(i) && push!(seen, seen_count())
end

# `global` declaration makes target global inside function: fix is manual.
function count_seen()
    global seen_twice
    seen_twice = Int[]
    for i in 1:4
        iseven(i) && push!(seen_twice, seen_count())
    end
    return seen_twice
end

# Package binds own `NTuple`: annotation may name mutable type whose length loop changes, so fix is manual.
mutable struct NTuple
end
function grown(items::NTuple)
    out = Int[]
    for x in items
        push!(out, 2x)
    end
    return out
end

# Package defines own `Base` module: `Base.Tuple` may name its mutable type, so fix is manual.
module Base
mutable struct Tuple
end
end
function regrown(items::Base.Tuple)
    out = Int[]
    for x in items
        push!(out, 2x)
    end
    return out
end
