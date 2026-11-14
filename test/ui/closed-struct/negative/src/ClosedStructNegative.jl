# runic: off
"""Package whose public structs have abstract supertypes, and whose closed structs are private."""
module ClosedStructNegative

export AbstractModel, Model, Point, Failure, Unit, Some, Bytes, Shape, area, ORIGIN, Pending

"""Model interface."""
abstract type AbstractModel end

"""Linear model."""
struct Model <: AbstractModel
    weights::Vector{Float64}
end

"""Model of any subtype with `size` zero weights."""
(::Type{M})(size::Int) where {M <: AbstractModel} = M(zeros(size))

"""Point in plane."""
struct Point{T} <: AbstractVector{T}
    x::T
    y::T
end

"""Error with message."""
struct Failure <: Exception
    message::String
end

"""Bit pattern."""
primitive type Unit 8 end

"""Shape interface."""
abstract type Shape end

"""Area of shape."""
area(shape::Shape)::Float64 = 0.0

"""Private cache."""
struct Cache
    entries::Dict{String, Int}
end

const Bytes = Vector{UInt8}
const ORIGIN = (0, 0)

end
