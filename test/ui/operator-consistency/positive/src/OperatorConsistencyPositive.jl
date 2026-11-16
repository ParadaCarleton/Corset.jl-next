# runic: off
"""Package whose equality, hash and comparison methods break Base contracts."""
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
Base.hash(point::Point{Int}, h::UInt) = hash(point.x, h)

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

"""Span with float ends, hashed without `isequal`."""
struct Span
    ends::NTuple{2, Float64}
end
Base.:(==)(a::Span, b::Span) = a.ends == b.ends
Base.hash(span::Span, h::UInt) = hash(span.ends, h)

"""Account compared by id; hash also reads cache."""
struct Account
    id::Int
    cache::Vector{Int}
end
Base.:(==)(a::Account, b::Account) = a.id == b.id
function Base.hash(account::Account, h::UInt)
    seen = account.cache
    return hash(seen, hash(account.id, h))
end

"""Node hashed by id, compared by identity."""
mutable struct Node
    id::Int
end
Base.hash(node::Node, h::UInt) = hash(node.id, h)

"""Bag hashed by items; `===` compares item vector by identity."""
struct Bag
    items::Vector{Int}
end
Base.hash(bag::Bag, h::UInt) = hash(bag.items, h)

"""Key whose `hash` gives `h` default."""
struct Key
    id::Int
end
Base.:(==)(a::Key, b::Key) = a.id == b.id
Base.hash(key::Key, h::UInt = zero(UInt)) = hash(key.id, h)

"""Job compared by name and priority, ordered by priority."""
struct Job
    name::String
    priority::Int
end
Base.:(==)(a::Job, b::Job) = a.name == b.name && a.priority == b.priority
Base.hash(job::Job, h::UInt) = hash(job.priority, hash(job.name, h))
Base.isless(a::Job, b::Job) = isless(getfield(a, :priority), b.priority)
end
