# runic: off
"""Fixture of `unwritten-element`: arrays written before read, and arrays whose uses leave method."""
module UnwrittenElementNegative

copied(x::Vector{Float64}) = (y = similar(x); copyto!(y, x); sum(y))

filled(n::Int) = (a = Vector{Float64}(undef, n); fill!(a, 0.0); sum(a))

function looped(x::Vector{Float64})
    y = similar(x)
    for i in eachindex(y)
        y[i] = 2x[i]
    end
    return sum(y)
end

pair() = (a = Vector{Int}(undef, 2); a[1] = 1; a[2] = 2; sum(a))

first_only() = (a = Vector{Int}(undef, 2); a[1] = 1; a[1])

returned(n::Int) = Vector{Float64}(undef, n)

# Call can return array itself: `fill!` through result writes array.
settled(a::Vector{Float64}) = a
settled_fill(n::Int) = (a = Vector{Float64}(undef, n); fill!(settled(a), 0.0); sum(a))

# `@inbounds` view skips bounds check: it reads no index.
unchecked(values::Vector{Float64}) = (indices = Vector{Int}(undef, 2); v = @inbounds view(values, indices); length(v))

# `.=` into every element of array writes it whole.
spliced(x::Vector{Float64}) = (a = Vector{Float64}(undef, length(x)); a[1:end] .= x; sum(a))
cleared(n::Int) = (a = Matrix{Float64}(undef, n, n); a[:, :] .= 0.0; sum(a))

# `isassigned` tests element without read.
assigned(n::Int) = (a = Vector{String}(undef, n); isassigned(a, 1))

full() = (a = zeros(2); a[1] = 1.0; a[2] = 2.0; sum(a))

basis_entry() = (e = zeros(3); e[1] = 1.0; e[2])

# Functor before array: `!` call can write array, as Distances `colwise!(metric, r, a, b)` does.
abstract type Metric end
struct Gap <: Metric end
(::Gap)(a::Float64, b::Float64) = abs(a - b)
function gaps!(metric::Metric, r::AbstractVector{Float64}, a::AbstractVector{Float64}, b::AbstractVector{Float64})
    for i in eachindex(r, a, b)
        r[i] = metric(a[i], b[i])
    end
    return r
end
gaps(metric::Metric, a::Vector{Float64}, b::Vector{Float64}) = (r = Vector{Float64}(undef, length(a)); gaps!(metric, r, a, b))

end
