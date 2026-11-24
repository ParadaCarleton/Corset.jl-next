# runic: off
"""Fixture of `broadcast-rebind`: loops that replace buffer with new broadcast array."""
module BroadcastRebindPositive

function decay(n::Int)
    x = ones(4)
    for _ in 1:n
        x = x .* 0.5
    end
    return x
end

function rooted(x::Vector{Float64}, n::Int)
    y = copy(x)
    k = 0
    while k < n
        y = sqrt.(y)
        k += 1
    end
    return y
end

# Read before rebind sees old elements either way.
function damped(n::Int)
    total = 0.0
    x = fill(2.0, 3)
    for _ in 1:n
        total += sum(x::Vector{Float64})
        x = x ./ 2
    end
    return total
end

# Comment before `=` holds `=`: fix edits assignment token.
function commented(n::Int)
    x = ones(2)
    for _ in 1:n
        x #= a = b =# = x .+ 1.0
    end
    return x
end

# Macro on right side: `.=` takes it.
function halved(n::Int)
    x = ones(3)
    for _ in 1:n
        x = @. x / 2
    end
    return x
end

# Explicit broadcast reuses inner broadcast; `.=` would not fuse it: fix is manual.
function doubled(n::Int)
    x = ones(3)
    for _ in 1:n
        b = Base.broadcasted(+, x, x)
        x = Base.materialize(Base.broadcasted(*, b, b))
    end
    return x
end

# Buffer from tuple assignment has no plain assignment: fix is manual.
function paired(n::Int)
    x, y = ones(2), zeros(2)
    for _ in 1:n
        x = x .* 2
    end
    return x, y
end

# Buffer under other name: fix is manual.
function renamed(n::Int)
    start = ones(3)
    x = start
    for _ in 1:n
        x = x .* 2
    end
    return x
end

end
