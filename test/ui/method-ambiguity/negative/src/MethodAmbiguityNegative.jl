# runic: off
"""Method sets without ambiguity."""
module MethodAmbiguityNegative

# Intersection method resolves pair.
combine(left::Int, right) = left
combine(left, right::Int) = right
combine(left::Int, right::Int) = left + right

# One method more specific than other.
scale(factor::Real, values::AbstractVector) = factor .* values
scale(factor::Integer, values::AbstractVector{<:Integer}) = factor .* values

# Disjoint argument types.
describe(value::Int) = "integer"
describe(value::String) = "text"

"""Value in box."""
struct Wrapper
    inner::Int
end

# Ambiguous with Base `convert(::Type{T}, ::T)`: other package owns one side.
Base.convert(::Type{T}, value::Wrapper) where {T} = T(value.inner)

end
