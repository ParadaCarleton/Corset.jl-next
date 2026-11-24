# runic: off
module IntermediateWideningNegative

half32(x::AbstractFloat) = Float32(x * oftype(x, 0.5))
# Widened result escapes; `type-disruption` reports it.
scaled(x::AbstractFloat) = x * 0.5
# Declared result converts constant; nothing computes in wider type.
(clamped(x::T)::T) where {T <: AbstractFloat} = x > 0 ? 0.5 : x
# Integer input takes no part.
following(xs::AbstractVector{<:Real}, i::Integer) = xs[2i]

struct Knobs{T <: Real}
    scale::T
end
# Callee `T` takes input type, so `log(T(4))` is no weak value; field of `knobs` widens.
function bracket(knobs::Knobs, x::T)::NTuple{2, T} where {T <: Real}
    lower = log(knobs.scale * x / 2)
    return lower, lower + log(T(4))
end

end
