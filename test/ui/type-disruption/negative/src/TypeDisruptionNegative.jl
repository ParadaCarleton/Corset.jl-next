# runic: off
module TypeDisruptionNegative

scaled(x::AbstractFloat) = x * oftype(x, 0.5)
# Integer literal takes float input type.
doubled(x::AbstractFloat) = 2x
# Division gives `Float64` for every integer type.
halves(n::Integer) = n / 2
# Float literal makes integer input float on purpose.
shifted(n::Integer) = n + 0.5
squared(x::AbstractFloat) = x^2

function total(xs::AbstractVector{<:Real})
    s = zero(eltype(xs))
    for x in xs
        s += x
    end
    return s
end

# Index converts to `Int`.
following(xs::AbstractVector{<:Real}, i::Integer) = xs[i + 1]
window(xs::AbstractVector{<:Real}, i::Integer) = sum(xs[1:2i])
# Size takes no part in element type.
filled(n::Integer) = fill(0, n)
# Conversion to narrowest float type keeps `Float32` input.
narrowed(x::AbstractFloat) = Float32(x)
# Concrete element type converts stored value; `intermediate-widening` reports it.
function record!(log::Vector{Float32}, x::AbstractFloat)
    log[1] = x * 2.0
    return nothing
end

end
