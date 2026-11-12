# runic: off
function setup!(state)
    state.ready = true
    state.count = 0
    return state
end

next!(rng)
skip!(rng)
