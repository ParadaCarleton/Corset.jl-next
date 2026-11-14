# runic: off
"""Package whose argument types accept containers of subtypes."""
module InvariantParameterNegative

"""Item in inventory."""
abstract type Item end

"""Sum of `values`."""
total(values::Vector{<:Real})::Real = sum(values)

"""Sum of `values`, element type as type variable."""
generic(values::Vector{T}) where {T <: Real} = sum(values)

"""First of `items`; type variable `Item` shadows abstract type of same name."""
first_item(items::Vector{Item}) where {Item} = items[1]

"""Sum of pair: `Tuple` is covariant."""
pair_sum(pair::Tuple{Real, Real})::Real = pair[1] + pair[2]

"""Length of mixed vector: `Any` holds mixed values on purpose."""
mixed(values::Vector{Any})::Int = length(values)

"""Name of type `Real` itself."""
kind(::Type{Real})::String = "real"

"""Count of entries with concrete parameters."""
lookup(table::Dict{Symbol, Int})::Int = length(table)

"""Value of `Val`."""
unval(::Val{3})::Int = 3

"""Count of rows: dimension parameter is value."""
rows(matrix::Array{Int, 2})::Int = size(matrix, 1)
end
