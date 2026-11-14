# runic: off
"""Package whose equality methods have matching hash, and whose comparisons define source operators only."""
module OperatorConsistencyNegative

"""Shape compared by area."""
abstract type Shape end
Base.hash(shape::Shape, h::UInt) = hash(area(shape), h)

"""Square with side length."""
struct Square <: Shape
    side::Int
end
"""Area of `square`."""
area(square::Square)::Int = square.side^2
Base.:(==)(a::Square, b::Square) = area(a) == area(b)
Base.:(<)(a::Square, b::Square) = area(a) < area(b)
Base.:(<=)(a::Square, b::Square) = area(a) <= area(b)

"""Circle with radius; equality on type variable bounded by package type."""
struct Circle <: Shape
    radius::Int
end
"""Area of `circle`, rounded."""
area(circle::Circle)::Int = round(Int, pi * circle.radius^2)
Base.:(==)(a::C, b::C) where {C <: Circle} = a.radius == b.radius

"""Wrapper hashed for one parameter only."""
struct Wrapper{T}
    content::T
end
Base.:(==)(a::Wrapper{Int}, b::Wrapper{Int}) = a.content == b.content
Base.hash(wrapper::Wrapper{Int}, h::UInt) = hash(wrapper.content, h)
Base.:(==)(a::Union{Square, Wrapper}, b::Int) = false
end
