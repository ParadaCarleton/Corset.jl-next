# runic: off
module ImpureLambdaNegative

# Read-only capture: predicate reads set it does not change.
function known(items::Vector{Int}, seen::Set{Int})
    return filter(item -> item in seen, items)
end

doubled(items::Vector{Float64}) = map(item -> 2item, items)

# `map` consumes stateful iterator; anonymous function stays pure.
doubled_rest(rest::Iterators.Stateful{Vector{Int}}) = map(item -> 2item, rest)

# Scratch array lives inside each call of anonymous function.
function spread(items::Vector{Float64})
    return map(items) do item
        buffer = zeros(2)
        buffer[1] = item
        sum(buffer)
    end
end

# `foreach` runs function for its effects.
function record!(log::Vector{Int}, items::Vector{Int})
    foreach(item -> push!(log, item), items)
    return log
end

# Bang function writes its own first argument; anonymous function stays pure.
function negate!(items::Vector{Int})
    sort!(items; by = item -> -item)
    return map!(item -> -item, items, items)
end

# Named function with `!` states its write.
function logged(log::Vector{Int}, items::Vector{Int})
    log_item!(item::Int) = (push!(log, item); item)
    return map(log_item!, items)
end

# Comprehension is loop, which runs in order.
function squares!(log::Vector{Int}, items::Vector{Int})
    return [(push!(log, item); item^2) for item in items]
end

end
