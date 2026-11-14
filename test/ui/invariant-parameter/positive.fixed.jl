# runic: off
"""Package whose argument types reject containers of subtypes."""
module InvariantParameterPositive

"""Shape with area."""
abstract type Shape end

"""Sum of `values`."""
total(values::Vector{<:Real})::Real = sum(values)

"""Area by name, scaled by first entry of `scale`."""
function areas(table::Dict{String, <:Shape}; scale::AbstractVector{<:Base.Real} = Real[1.0])::Dict{String, Real}
    return Dict(name => scale[1] for name in keys(table))
end

"""Widths of `rows`, times `factor`; default argument gives two methods."""
widths(rows::Vector{<:Real}...; factor = 2)::Vector{Int} = [factor * length(row) for row in rows]

"""Lengths of `shapes`, with default count."""
counted(shapes::Vector{<:Shape}, count::Int = 1)::Int = count * length(shapes)
end
