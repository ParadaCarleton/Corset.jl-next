# runic: off
module IntermediateWideningNegative

half32(x::AbstractFloat) = Float32(x * oftype(x, 0.5))
# Widened result escapes; `type-disruption` reports it.
scaled(x::AbstractFloat) = x * 0.5
# Index converts to `Int`.
following(xs::AbstractVector{<:Real}, i::Integer) = xs[2i]

end
