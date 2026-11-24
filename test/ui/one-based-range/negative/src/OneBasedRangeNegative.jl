# runic: off
module OneBasedRangeNegative

function total(xs::AbstractVector{Float64})
    s = 0.0
    for i in eachindex(xs)
        s += xs[i]
    end
    return s
end

head(xs::AbstractVector{Int}) = xs[begin]

tail(xs::AbstractVector{Int}) = xs[end]

# `eachindex(xs, ys)` throws on different axes, so index fits both.
function copy_into!(ys::AbstractVector{Int}, xs::AbstractVector{Int})
    for i in eachindex(ys, xs)
        ys[i] = xs[i]
    end
    return ys
end

function added!(ys::AbstractVector{Int}, xs::AbstractVector{Int})
    axes(ys) == axes(xs) || throw(DimensionMismatch("axes differ"))
    for i in eachindex(xs)
        ys[i] += xs[i]
    end
    return ys
end

function guarded_head(xs::AbstractVector{Int})
    Base.require_one_based_indexing(xs)
    return xs[1]
end

function doubled(xs::AbstractVector{Float64})
    out = similar(xs)
    for (i, x) in pairs(xs)
        out[i] = 2x
    end
    return out
end

# Index plus half distance to other index stays index.
function first_at_least(xs::AbstractVector{Int}, target::Int)
    lo, hi = firstindex(xs), lastindex(xs) + 1
    while lo < hi
        mid = lo + (hi - lo) ÷ 2
        if xs[mid] < target
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

function trace(m::AbstractMatrix{Float64})
    s = 0.0
    for i in axes(m, 1)
        s += m[i, i - first(axes(m, 1)) + first(axes(m, 2))]
    end
    return s
end

function zeroed!(m::AbstractMatrix{Float64})
    for index in CartesianIndices(m)
        m[index] = 0.0
    end
    return m
end

function first_positive(xs::AbstractVector{Int})
    i = findfirst(>(0), xs)
    return isnothing(i) ? nothing : xs[i]
end

function largest(xs::AbstractVector{Float64})
    _, i = findmax(xs)
    return xs[i]
end

function simd_total(xs::AbstractVector{Float64}, ys::AbstractVector{Float64})
    s = 0.0
    @simd for i in eachindex(xs, ys)
        @inbounds s += xs[i] * ys[i]
    end
    return s
end

function column_sums(m::AbstractMatrix{Float64})
    sums = zeros(size(m, 2))
    for (k, column) in enumerate(axes(m, 2))
        sums[k] = sum(view(m, :, column))
    end
    return sums
end

# Caller proves index argument.
at(xs::AbstractVector{Int}, i::Int) = xs[i]

# Index from axes of array that callee indexes.
first_at(xs::AbstractVector{Int}) = at(xs, firstindex(xs))

# Method that passes index and array on: its callers prove index.
forward(xs::AbstractVector{Int}, i::Int) = at(xs, i)
last_forwarded(xs::AbstractVector{Int}) = forward(xs, lastindex(xs))

# One-based guard before call.
guarded_at(xs::AbstractVector{Int}) = (Base.require_one_based_indexing(xs); at(xs, 1))

# Axes agreement: index of `ys` indexes `xs`.
function agreed_at(xs::AbstractVector{Int}, ys::AbstractVector{Int})
    axes(xs) == axes(ys) || throw(DimensionMismatch("axes differ"))
    return at(xs, firstindex(ys))
end

# `Vector` axes start at 1.
vector_at(xs::Vector{Int}) = at(xs, 1)

# Arithmetic of two index arguments: no contract names either.
shifted(xs::AbstractVector{Int}, i::Int, delta::Int) = xs[i + delta]
second(xs::AbstractVector{Int}) = shifted(xs, firstindex(xs), 1)

# `Vector` axes start at 1.
head_of(xs::Vector{Int}) = xs[1]

# Range between index arguments: caller proves both.
slice(xs::AbstractVector{Int}, lo::Int, hi::Int) = xs[lo:hi]

# Index argument capped by last index of same array.
capped(xs::AbstractVector{Int}, i::Int) = xs[min(i, lastindex(xs))]

# Broadcast of `xs` with scalar has axes of `xs`.
function scaled_head(xs::AbstractVector{Float64})
    ys = xs .* 2.0 .+ 1.0
    return ys[firstindex(xs)]
end

# Guard proves indices in blocks after it.
function guarded_total(xs::AbstractVector{Int})
    Base.require_one_based_indexing(xs)
    s = 0
    for i in 1:length(xs)
        s += xs[i]
    end
    return s
end

# Ends of tuple of indices are indices.
function ends(xs::AbstractVector{Int})
    bounds = (firstindex(xs), lastindex(xs))
    return xs[first(bounds)] + xs[last(bounds)]
end

end
