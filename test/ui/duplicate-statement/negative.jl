# runic: off
function setup!(state)
    state.ready = true
    state.count = 0
    return state
end

next!(rng)
skip!(rng)

"""Area of unit circle."""
area() = pi
perimeter() = 2pi
