# runic: off
"""Shapes."""
module Shapes

"""Area of unit circle."""
function area()
    return pi
end

    """
    Perimeter of square
    with side `s`.
    """
    perimeter(s) = 4s

module Inner
end

end

begin
    """Volume of unit cube."""
    volume() = 1
end

"""Sum without bounds checks."""
@inline fast_sum(a, b) = a + b
