# runic: off
"""Ambiguous method pairs."""
module MethodAmbiguityPositive

combine(left::Int, right) = left
combine(left, right::Int) = right

function scale(factor::Real, values::AbstractVector{<:Integer})
    return factor .* values
end
scale(factor::Integer, values::AbstractVector) = factor .* values

pad(text::AbstractString, width::Integer = 8; fill::Char = ' ') = lpad(text, width, fill)
pad(text, width::Int) = text

"""Shape with side."""
struct Square
    side::Float64
end
Square(side::Integer, unit) = Square(Float64(side))
Square(side, unit::Symbol) = Square(Float64(side))

same(first::T, second::T) where {T} = true
same(first::Int, second) = false

gather(first::Int, rest...) = first
gather(first, rest::Int...) = rest

nest(values::AbstractArray{T, N}, index::Int) where {T, N} = values
nest(values::Array, index::Integer) = values

# Both definitions on one line: one finding.
twin(left::Int, right) = left; twin(left, right::Int) = right

module Inner
import ..MethodAmbiguityPositive: combine
combine(left::Float64, right) = left
combine(left, right::Float64) = right
end

end
