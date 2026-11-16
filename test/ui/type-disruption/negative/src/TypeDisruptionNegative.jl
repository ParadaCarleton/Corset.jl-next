# runic: off
module TypeDisruptionNegative

scaled(x::AbstractFloat) = x * oftype(x, 0.5)
# Integer literal takes float input type.
doubled(x::AbstractFloat) = 2x
squared(x::AbstractFloat) = x^2

function total(xs::AbstractVector{<:Real})
    s = zero(eltype(xs))
    for x in xs
        s += x
    end
    return s
end

# Julia promotes small integers to `Int` on purpose, so integer input takes no part.
doubled(n::Integer) = 2n
halves(n::Integer) = n / 2
shifted(n::Integer) = n + 0.5
following(xs::AbstractVector{<:Real}, i::Integer) = xs[i + 1]
filled(n::Integer) = fill(0, n)
# Conversion to narrowest float type keeps `Float32` input.
narrowed(x::AbstractFloat) = Float32(x)
# Array built from input keeps caller's array type.
function doubled_all(xs::AbstractVector{<:AbstractFloat})
    out = similar(xs)
    out .= 2 .* xs
    return out
end
# No input array, so no caller's array type to keep.
grid(n::Int) = zeros(n, n)
# Buffer neither meets input nor leaves method.
function counted_sum(xs::AbstractVector, n::Int)
    counts = zeros(Int, n)
    for i in 1:n
        counts[i] = i
    end
    return sum(counts)
end
# Callee takes `Array` only.
measured(xs::AbstractVector) = array_length(zeros(length(xs)))
array_length(a::Array) = length(a)
# Concrete element type converts stored array.
function cache!(cache::Vector{Vector{Float64}}, xs::AbstractVector)
    cache[1] = zeros(length(xs))
    return nothing
end
# Concrete element type converts stored value; `intermediate-widening` reports it.
function record!(log::Vector{Float32}, x::AbstractFloat)
    log[1] = x * 2.0
    return nothing
end

end
