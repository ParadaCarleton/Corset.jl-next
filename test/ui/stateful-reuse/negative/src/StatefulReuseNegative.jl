# runic: off
module StatefulReuseNegative

# Arrays start from first element each time.
mean_or_zero(xs::Vector{Float64}) = isempty(xs) ? 0.0 : sum(xs) / length(xs)

# `Iterators.peel` takes first element once.
function head_and_rest(itr::Any)
    peeled = Iterators.peel(itr)
    isnothing(peeled) && return nothing
    head, rest = peeled
    return (head, collect(rest))
end

# Loop threads `iterate` state: one start.
function count_items(itr::Any)
    n, next = 0, iterate(itr)
    while next !== nothing
        n += 1
        next = iterate(itr, next[2])
    end
    return n
end

# One pass over argument.
total(itr::Any) = sum(itr)

# `eachline` result is stateful: `isempty` checks end of stream, and `first` skips header on purpose.
function count_rows(io::IO)
    lines = eachline(io)
    isempty(lines) && return 0
    header = first(lines)
    return count(line -> line != header, lines)
end

# `Iterators.partition` keeps batch length as `Int`: pass over batches iterates range, never `batch_length`.
function batch_mean(statistic::F, context::Any, count::Integer, batch_length::Integer)::Float64 where {F}
    batches = batch_total(count, batch_length)
    per_batch = Float64[statistic(context, indices) for indices in Iterators.partition(1:count, batch_length)]
    return sum(per_batch) / batches
end

# Check that throws keeps call out of line, so `batch_length` escapes to package function before pass.
function batch_total(count::Integer, batch_length::Integer)::Integer
    if batch_length < 1 || count % batch_length != 0
        throw(ArgumentError("$count draws do not split into batches of length $batch_length"))
    end
    return count ÷ batch_length
end

# Destructuring starts new element on each pass.
function pair_sum(entries::Any)
    total = 0
    for (a, b) in entries
        total += a + b
    end
    return total
end

end
