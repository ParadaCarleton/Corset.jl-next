# runic: off
"""Shapes."""
module Shapes

"""Area of unit circle."""
function area()
    return pi
end

# corset: allow annotation -- demo
perimeter(s) = 4s

side = 1  # unit

end

function outer()
    # Local helper: docstring here would be plain string.
    helper() = 1
    return helper()
end

function outer_block()
    begin
        inner() = 1
    end
    # Local helper after block.
    helper() = 1
    return helper()
end

# Callback for tests.
handler = function (x)
    return x
end
