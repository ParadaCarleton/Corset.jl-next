# runic: off
"""Package whose functions annotate narrower types than their code needs."""
module OverspecifiedTypePositive

export scale, area, total, middle, weighted, present, rows, absolute, Point, power, code, rounded
public counted, sizes, members, mean

"""Scaled copy of values."""
scale(values::Vector{Float64}, factor::Float64) = values .* factor

"""Area of circle."""
area(radius::AbstractFloat) = pi * radius^2

"""Sum of counts."""
total(counts::Dict{String, Int}) = sum(values(counts))

"""Midpoint of two integers."""
middle(low::Union{Int32, Int64}, high::Union{Int32, Float64}) = (low + high) / 2

"""Half sum of pair, times weight."""
weighted(pair::NTuple{2, Float64}; weight::Float32 = 1.0f0) = weight * sum(pair) / 2

"""Whether value is present."""
present(value::Union{Nothing, Float64}) = value !== nothing

"""Row count of grid."""
rows(grid::Matrix{<:Real}) = size(grid, 1)

"""Sum of absolute values."""
absolute(values::Base.Vector{Float64}) = sum(abs, values)

"""Count plus start; two methods, one report per annotation."""
counted(items::Vector{Int}, start::Int = 0) = start + length(items)

"""Point in plane; inner constructor takes only `Float64`."""
struct Point
    x::Float64
    y::Float64
    Point(x::Float64, y::Float64) = new(x, y)
end

"""Member count of vector or set."""
members(collection::Union{Vector, Set}) = length(collection)

"""Mean of values with float elements."""
mean(values::AbstractVector{<:Float64}) = sum(values) / length(values)

"""Power of base; widened method would overlap `Integer` method, so call `power(2, 3)` becomes ambiguous."""
power(base::Float64, exponent::Int) = base^exponent
power(base::Integer, exponent) = base^exponent

"""Codes of byte and word; both widen to `Integer`, so later method would replace earlier one."""
code(value::Int8) = 1
code(value::Int) = 2

"""Rounded value; widened methods nest, `Integer` inside `Real`, so dispatch keeps both."""
rounded(value::Float64) = round(Int, value)
rounded(value::Int) = value

"""Lengths of named groups."""
sizes(groups::Dict{Symbol, Vector{Float64}}) = Dict(name => length(group) for (name, group) in groups)

end
