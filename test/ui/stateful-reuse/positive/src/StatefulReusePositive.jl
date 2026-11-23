# runic: off
module StatefulReusePositive

# Loop after `first` starts argument again: stateful iterator skips first element.
function spread(itr::Any)
    low = first(itr)
    high = low
    for x in itr
        high = max(high, x)
    end
    return high - low
end

# `isempty` can iterate argument, so sum after it can miss first element.
function checked_sum(itr::Any)
    isempty(itr) && return 0
    return sum(itr)
end

# `zip` of argument with itself starts it twice.
self_pairs(itr::Any) = collect(zip(itr, itr))

# Started iterator escapes to caller.
function split_head(itr::Any)
    head = first(itr)
    return (head, itr)
end

# `first` inside loop starts iterator on each pass.
function firsts(itr::Any, n::Int)
    out = Any[]
    for _ in 1:n
        push!(out, first(itr))
    end
    return out
end

end
