# runic: off
"""Package whose equality, hash and comparison methods keep Base contracts, and whose comparisons define source operators only."""
module OperatorConsistencyNegative

"""Shape compared by area."""
abstract type Shape end
Base.hash(shape::Shape, h::UInt) = hash(area(shape), h)
Base.:(==)(a::Shape, b::Shape) = area(a) == area(b)

"""Named thing hashed by name; abstract, so `===` on subtypes decides identity."""
abstract type Named end
Base.hash(named::Named, h::UInt) = hash(named.name, h)

"""Length in meters, equal to plain number; no method compares two `Meters`."""
struct Meters
    value::Float64
end
Base.:(==)(a::Meters, b::Real) = a.value == b
Base.hash(meters::Meters, h::UInt) = hash(meters.value, h)

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

"""Interval with float ends; `isequal`, `hash` and `isless` read same fields."""
struct Interval
    low::Float64
    high::Float64
end
Base.:(==)(a::Interval, b::Interval) = a.low == b.low && a.high == b.high
Base.isequal(a::Interval, b::Interval) = isequal(a.low, b.low) && isequal(a.high, b.high)
Base.hash(interval::Interval, h::UInt) = hash(interval.high, hash(getfield(interval, :low), h))
Base.isless(a::Interval, b::Interval) = isless((a.low, a.high), (b.low, b.high))

"""Pixel hashed by coordinates; `===` compares bits, so equal pixels match."""
struct Pixel
    x::Int
    y::Int
end
Base.hash(pixel::Pixel, h::UInt) = hash(pixel.x, hash(pixel.y, h))

"""Name hashed by text; `===` compares strings by content."""
struct Name
    text::String
end
Base.hash(name::Name, h::UInt) = hash(name.text, h)

"""Counter hashed by identity on purpose."""
mutable struct Counter
    count::Int
end
Base.hash(counter::Counter, h::UInt) = hash(objectid(counter), h)

"""Label compared by text; hash reads fewer fields than equality."""
struct Label
    text::String
    color::Symbol
end
Base.:(==)(a::Label, b::Label) = a.text == b.text && a.color == b.color
Base.hash(label::Label, h::UInt) = hash(label.text, h)

"""Frame compared by pixel; `hash` rebinds argument, so fields it reads after belong to pixel."""
struct Frame
    pixel::Pixel
end
Base.:(==)(a::Frame, b::Frame) = a.pixel == b.pixel
function Base.hash(frame::Frame, h::UInt)
    frame = frame.pixel
    return hash(frame.x, hash(frame.y, h))
end
end
