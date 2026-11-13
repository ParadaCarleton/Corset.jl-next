# runic: off
"""
    area(r)

Area of circle with radius `r`.
"""

area(r) = π * r^2

"Perimeter of square with side `s`."
# Four equal sides.
perimeter(s) = 4s

"Default tolerance."


const TOLERANCE = 1e-8

"Global counter."

counter = 0

"Fast sum."

@inline fast_sum(a, b) = a + b

"Shape types."

module Shapes

"Unit square."

struct Square end

"Any shape."

abstract type Shape end

"Raw byte."

primitive type Byte 8 end

end

begin
    "Volume of unit cube."

    volume() = 1
end

"Square of `x`."; square(x) = x^2

function process(items)
    "Process every item."
    for item in items
        handle(item)
        nothing
    end
    42
    :done
    'x'
    true
    return length(items)
end

function guarded(io)
    try
        read(io)
    finally
        close(io)
        nothing
    end
end

0x1f
setup(); 0; teardown()

# Sentinel for empty input.
-1

finish()
