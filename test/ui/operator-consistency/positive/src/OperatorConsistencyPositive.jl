# runic: off
"""Package whose equality and comparison methods break Base contracts."""
module OperatorConsistencyPositive

"""Tag set compared by names."""
struct Tags
    names::Vector{String}
end
Base.:(==)(a::Tags, b::Tags) = a.names == b.names
Base.isequal(a::Tags, b::Tags) = isequal(a.names, b.names)

"""Point with coordinate of any type."""
struct Point{T}
    x::T
end
Base.:(==)(a::Point{T}, b::Point{T}) where {T} = a.x == b.x

"""Ring ordered by radius."""
struct Ring
    radius::Int
end
Base.:(==)(a::Ring, b::Ring) = a.radius == b.radius
Base.hash(ring::Ring, h::UInt) = hash(ring.radius, h)
Base.:(<)(a::Ring, b::Ring) = a.radius < b.radius
Base.:(!=)(a::Ring, b::Ring) = a.radius != b.radius
Base.:(>)(a::Ring, b::Ring) = a.radius > b.radius
Base.:(>=)(a::Ring, b::Ring) = a.radius >= b.radius
end
