# runic: off
"""Methods on functions and types package does not own."""
module PiracyPositive

"""Empty box."""
struct Box end

"""Name of box."""
describe(box::Box) = "box"

# Alias of other module's type: package does not own it.
const Identifier = Base.UUID

Base.isone(name::Symbol) = name === :one

Base.:~(left::Char, right::Symbol) = string(left, right)

# Union with member package does not own.
Base.ncodeunits(boxes::Union{Box, Identifier}) = 0

# Constructor of other module's type.
Base.Int(name::Symbol, base::Char) = length(string(name))

function Base.reverse(names::Vector{Symbol}, flag::Val{1})
    return names
end

# Constructor for every subtype, and for union of types.
(::Type{T})(name::Symbol, base::Symbol) where {T <: Integer} = 0
(::Type{Union{Int8, Int16}})(name::Symbol) = 0

end
