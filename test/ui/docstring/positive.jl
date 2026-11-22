# runic: off
"""Shapes."""
module Shapes

# Area of unit circle.
function area()
    return pi
end

    # Perimeter of square
    # with side `s`.
    perimeter(s) = 4s

module Inner
end

end

begin
    # Volume of unit cube.
    volume() = 1
end

# Sum without bounds checks.
@inline fast_sum(a, b) = a + b

# String statement right above: fix keeps blank line, so string does not document new docstring.
"none"
# Volume of unit cube.
volume() = 1

# Costs $5; quote with """, path C:\temp.
cost() = 5

# Greets with "hi"
greet() = "hi"

# Comment line ends in multibyte character: Bessel order ν
bessel_order(ν) = ν
