# runic: off
"""Fixture of `broadcast-rebind`: loops where code sees old array, type widens, or axes can differ."""
module BroadcastRebindNegative

# Old array read after rebind: in place, it holds new elements.
function converged(x::Vector{Float64})
    y = copy(x)
    for _ in 1:10
        old = y
        y = y ./ 2
        maximum(abs.(y .- old)) < 1e-3 && break
    end
    return y
end

# Stored arrays: in place, each entry is same buffer.
function history(n::Int)
    x = ones(2)
    kept = Vector{Float64}[]
    for _ in 1:n
        x = x .* 2
        push!(kept, x)
    end
    return kept
end

# Element type widens: `.=` throws `InexactError`.
function halves(n::Int)
    x = ones(Int, 3)
    for _ in 1:n
        x = x ./ 2
    end
    return x
end

# Other array operand can have other axes.
function shifted(x::Vector{Float64}, n::Int)
    y = zeros(length(x))
    for _ in 1:n
        y = y .+ x
    end
    return y
end

# First buffer read after loop.
function grown(n::Int)
    start = ones(3)
    x = start
    for _ in 1:n
        x = x .* 2
    end
    return sum(x) - sum(start)
end

# Outer loop starts each inner loop from same buffer.
function restarted(n::Int)
    start = ones(3)
    total = 0.0
    for _ in 1:n
        x = start
        for _ in 1:3
            x = x .* 2
        end
        total += sum(x)
    end
    return total
end

# Loop exits after rebind: old array outlives loop.
function previous(n::Int)
    x = ones(3)
    old = x
    while true
        old = x
        x = x .* 2
        sum(x) > n && break
    end
    return old
end

end
