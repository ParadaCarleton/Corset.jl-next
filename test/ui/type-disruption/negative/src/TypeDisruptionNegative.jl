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
# Concrete element type converts stored value; `intermediate-widening` reports it.
function record!(log::Vector{Float32}, x::AbstractFloat)
    log[1] = x * 2.0
    return nothing
end

end
