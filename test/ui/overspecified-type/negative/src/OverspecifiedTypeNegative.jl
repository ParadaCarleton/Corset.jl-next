# runic: off
"""Package whose annotations name what code needs, or fast paths beside generic methods."""
module OverspecifiedTypeNegative

export scale, norm2, encode, zero_of, half, bounded, anything, Counter, Geometry, generic

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

"""Sum through private helper whose `Vector{Float64}` method is fast path beside generic one."""
generic(values) = generic_sum(values)
generic_sum(values) = sum(values)
generic_sum(values::Vector{Float64}) = sum(values)

"""Methods on Base constructor of Base type follow Base signatures."""
Base.Float64(counter::Counter) = Float64(counter.count)

"""Registers name; inserted dictionary keeps `Dict`."""
register(table::Dict{Symbol, Any}, name::Symbol) = (table[name] = nothing; table)

"""Pushes values through closure that captures resized vector."""
collect_into(items::Vector{Any}, values) = foreach(value -> push!(items, value), values)

"""Forwards resized vector to package function."""
forward_into(items::Vector{Any}) = collect_into(items, (1, 2))

"""Holder of names."""
struct Names
    names::Vector{Symbol}
end

"""Wraps names; field type `Vector{Symbol}` needs argument type."""
wrap_names(names::Vector{Symbol}) = Names(names)

"""First item; rule reads no `where` inside annotation."""
first_of(items::Union{Vector{T}, Set{T}} where {T}) = first(items)

"""First item of first reference; rule reads no `where` inside annotation."""
first_ref(items::Vector{Ref{T}} where {T}) = first(items)[]

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
