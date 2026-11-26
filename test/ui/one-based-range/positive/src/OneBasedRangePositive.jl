# runic: off
module OneBasedRangePositive

# Loop over `1:length(xs)` assumes axes start at 1.
function total(xs::AbstractVector{Float64})
    s = 0.0
    for i in 1:length(xs)
        s += xs[i]
    end
    return s
end

# Literal index.
head(xs::AbstractVector{Int}) = xs[1]

# `enumerate` counter is absolute.
function doubled!(out::AbstractVector{Float64}, xs::AbstractVector{Float64})
    for (i, x) in enumerate(xs)
        out[i] = 2x
    end
    return out
end

# Index of `xs` need not index `ys`: axes can differ.
function copy_into!(ys::AbstractVector{Int}, xs::AbstractVector{Int})
    for i in eachindex(xs)
        ys[i] = xs[i]
    end
    return ys
end

# `size` is absolute in each dimension.
function trace(m::AbstractMatrix{Float64})
    s = 0.0
    for i in 1:size(m, 1)
        s += m[i, i]
    end
    return s
end

struct Picks
    at::Vector{Int}
end

# Stored index has unknown source.
function picked(picks::Picks, xs::AbstractVector{Float64})
    out = Float64[]
    for i in picks.at
        push!(out, xs[i])
    end
    return out
end

# Heap parent of index argument assumes one-based axes.
parent_of(xs::AbstractVector{Int}, i::Int) = xs[i ÷ 2]

# Sum of two indices overflows on axes near `typemin`.
function first_at_least(xs::AbstractVector{Int}, target::Int)
    lo, hi = firstindex(xs), lastindex(xs) + 1
    while lo < hi
        mid = (lo + hi) ÷ 2
        if xs[mid] < target
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

# Absolute start with index argument as end: range is no caller index.
prefix(xs::AbstractVector{Int}, n::Int) = xs[1:n]

# Branch that only offset axes reach still indexes with literal.
offset_only(xs::AbstractVector{Int}) = firstindex(xs) == 1 ? 0 : xs[1]

# Alias of `getindex` in branch that only offset axes reach.
aliased_offset(xs::AbstractVector{Int}) = (index = getindex; firstindex(xs) == 1 ? 0 : index(xs, 1))

# Arguments that share type take offset stand-in together.
both_heads(xs::T, ys::T) where {T <: AbstractVector{Int}} = xs[1] + ys[1]

# Index argument capped by index of other array: axes can differ.
capped_by(xs::AbstractVector{Int}, ys::AbstractVector{Int}, i::Int) = xs[min(i, firstindex(ys))]

# `size` without dimension is absolute in each field.
function corner(m::AbstractMatrix{Float64})
    rows, columns = size(m)
    return m[rows, columns]
end

# Callee indexes `xs` with its index argument: literal comes from no axes.
pick(xs::AbstractVector{Int}, i::Int) = xs[i]
first_pick(xs::AbstractVector{Int}) = pick(xs, 1)

# Method that passes index and array on takes contract of its callee.
forward(xs::AbstractVector{Int}, i::Int) = pick(xs, i)
forwarded_first(xs::AbstractVector{Int}) = forward(xs, 1)

# Index of array that call does not pass: axes can differ.
cross_pick(xs::AbstractVector{Int}, ys::AbstractVector{Int}) = pick(xs, firstindex(ys))

# Call in branch that only offset axes reach.
offset_pick(xs::AbstractVector{Int}) = firstindex(xs) == 1 ? 0 : pick(xs, 1)

# Alias of package function in branch that only offset axes reach.
aliased_pick(xs::AbstractVector{Int}) = (chosen = pick; firstindex(xs) == 1 ? 0 : chosen(xs, 1))

# Alias of array argument in branch that only offset axes reach.
renamed_pick(xs::AbstractVector{Int}) = (ys = xs; firstindex(ys) == 1 ? 0 : pick(ys, 1))

# Copy keeps axes of array argument.
copied_pick(xs::AbstractVector{Int}) = (ys = copy(xs); firstindex(xs) == 1 ? 0 : pick(ys, 1))

# Computed callee resolves to package function.
computed_pick(xs::AbstractVector{Int}) = firstindex(xs) == 1 ? 0 : getfield(@__MODULE__, :pick)(xs, 1)
either_pick(xs::AbstractVector{Int}, flag::Bool) = (g = flag ? copy : getfield(@__MODULE__, :pick); firstindex(xs) == 1 ? 0 : g(xs, 1))

struct Tag end

# Package method on `Base` function takes contract too.
Base.get(xs::AbstractVector{Int}, i::Int, ::Tag) = xs[i]
tagged_first(xs::AbstractVector{Int}) = get(xs, 1, Tag())

# Update reads and writes one element: one finding.
function bumped(xs::AbstractVector{Int})
    for i in 1:length(xs)
        xs[i] += 1
    end
    return xs
end

# Store and read of other elements on one line: two findings.
function shifted!(xs::AbstractVector{Int})
    xs[1] = xs[2]
    return xs
end

# Store and read of other elements of matrix on one line: two findings.
function shifted_row!(m::AbstractMatrix{Int})
    m[1, 2] = m[1, 3]
    return m
end

struct Shape
    count::Int
end

# Range holds its literal start, whatever its stop: definite.
function shape_total(xs::AbstractVector{Float64}, shape::Shape)
    s = 0.0
    for i in 1:shape.count
        s += xs[i]
    end
    return s
end

# Package range reads its arguments its own way: `length(xs)` is no start, so index is possible.
struct Shifted <: AbstractUnitRange{Int}
    count::Int
    offset::Int
end
Base.first(range::Shifted) = range.offset + 1
Base.last(range::Shifted) = range.offset + range.count

function shifted_total(xs::AbstractVector{Float64})
    s = 0.0
    for i in Shifted(length(xs), firstindex(xs) - 1)
        s += xs[i]
    end
    return s
end

# Package `:` method builds its own range: literal start proves nothing, so index is possible.
struct Stop end
Base.:(:)(::Int, ::Stop) = 0:2

function stopped_total(xs::AbstractVector{Int})
    s = 0
    for i in 1:Stop()
        s += xs[i]
    end
    return s
end

# Pirate `:` method on bits integers builds its own range too: possible. Test process loads it: pair no other code uses.
Base.:(:)(::Int, ::UInt128) = 0:2

function pirate_total(xs::AbstractVector{Int}, stop::UInt128)
    s = 0
    for i in 1:stop
        s += xs[i]
    end
    return s
end

end
