# runic: off
"""Methods with own function or own argument type."""
module PiracyNegative

"""Box of items."""
struct Box{T}
    items::Vector{T}
end

Base.length(box::Box) = length(box.items)
Base.:+(left::Box, right::Int) = left
Base.convert(::Type{Box}, items::Vector) = Box(items)

# Own type as parameter of other module's type.
Base.isempty(boxes::Vector{Box}) = true

# Symbol parameter counts as own.
Base.isone(flag::Val{:piracy_negative}) = true

# Own function on other modules' types.
describe(value::Int) = "integer"

"""Callable kind."""
abstract type Kind end
(kind::Kind)(value::Int) = value

# Declared name without value.
global pending

end
