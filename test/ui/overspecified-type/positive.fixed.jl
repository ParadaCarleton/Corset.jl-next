# ==> src/OverspecifiedTypePositive.jl
# runic: off
"""Package whose functions annotate narrower types than their code needs."""
module OverspecifiedTypePositive

export scale, area, total, middle, weighted, present, rows, absolute, Point
public counted, sizes, members, mean

"""Scaled copy of values."""
scale(values::AbstractVector{<:Real}, factor::Real) = values .* factor

"""Area of circle."""
area(radius::Real) = pi * radius^2

"""Sum of counts."""
total(counts::AbstractDict{String, <:Integer}) = sum(values(counts))

"""Midpoint of two integers."""
middle(low::Integer, high::Real) = (low + high) / 2

"""Half sum of pair, times weight."""
weighted(pair::NTuple{2, Real}; weight::Real = 1.0f0) = weight * sum(pair) / 2

"""Whether value is present."""
present(value::Union{Nothing, Real}) = value !== nothing

"""Row count of grid."""
rows(grid::AbstractMatrix{<:Real}) = size(grid, 1)

"""Sum of absolute values."""
absolute(values::AbstractVector{<:Real}) = sum(abs, values)

"""Count plus start; two methods, one report per annotation."""
counted(items::AbstractVector{<:Integer}, start::Integer = 0) = start + length(items)

"""Point in plane; inner constructor takes only `Float64`."""
struct Point
    x::Float64
    y::Float64
    Point(x::Real, y::Real) = new(x, y)
end

"""Member count of vector or set."""
members(collection::Union{AbstractVector, AbstractSet}) = length(collection)

"""Mean of values with float elements."""
mean(values::AbstractVector{<:Real}) = sum(values) / length(values)

"""Lengths of named groups."""
sizes(groups::AbstractDict{Symbol, <:AbstractVector{<:Real}}) = Dict(name => length(group) for (name, group) in groups)

end
