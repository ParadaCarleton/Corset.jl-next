# runic: off
module IntermediateWideningNegative

half32(x::AbstractFloat) = Float32(x * oftype(x, 0.5))
# Widened result escapes; `type-disruption` reports it.
scaled(x::AbstractFloat) = x * 0.5
# Declared result converts constant; nothing computes in wider type.
(clamped(x::T)::T) where {T <: AbstractFloat} = x > 0 ? 0.5 : x
# Integer input takes no part.
following(xs::AbstractVector{<:Real}, i::Integer) = xs[2i]

end
