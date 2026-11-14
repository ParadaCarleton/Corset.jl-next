# runic: off
"""Package whose annotations name what code needs, or fast paths beside generic methods."""
module OverspecifiedTypeNegative

export scale, norm2, encode, zero_of, half, bounded, anything, Counter, Geometry

"""Scaled copy of values."""
scale(values::AbstractVector{<:Real}, factor::Real) = values .* factor

"""Euclidean norm; `Vector{Float64}` method is fast path beside generic one."""
norm2(values::AbstractVector) = sqrt(sum(abs2, values))
norm2(values::Vector{Float64}) = sqrt(sum(abs2, values))

"""Flags, bytes, characters, text and C integers pass."""
encode(flag::Bool, byte::UInt8, letter::Char, text::String, code::Cint) = (flag, byte, letter, text, code)

"""Exact type and value parameters pass."""
zero_of(::Type{Float64}, ::Val{3}) = 0.0

"""Result type, `where` bound, `Any` and tuple of abstract types pass."""
half(x::Real)::Float64 = x / 2
bounded(x::T) where {T <: AbstractFloat} = x
anything(x::Any, pair::Tuple{Real, Real}) = (x, pair)

"""Counter of items."""
struct Counter
    count::Int
end

# Methods of Base functions follow Base signatures.
Base.getindex(counter::Counter, index::Int) = index
Base.iterate(counter::Counter, state::Int = 1) = state > counter.count ? nothing : (state, state + 1)

"""Private helper: no outside caller meets its annotation."""
helper(x::Float64) = 2x

"""Private struct; its constructor takes only `Float64`."""
struct Hidden
    value::Float64
    Hidden(value::Float64) = new(value)
end

"""Own `Vector` type; annotation names it, not Base `Vector`."""
module Geometry
export Vector, squared

"""Vector in plane."""
struct Vector
    x::Float64
    y::Float64
end

"""Squared length."""
squared(vector::Vector) = vector.x^2 + vector.y^2
end

end
