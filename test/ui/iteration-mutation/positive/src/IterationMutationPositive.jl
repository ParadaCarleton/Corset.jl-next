# runic: off
module IterationMutationPositive

function drop_empty!(groups::AbstractDict{String, Vector{Int}})
    for name in keys(groups)
        isempty(groups[name]) && delete!(groups, name)
    end
    return groups
end

function padded()
    xs = [1, 2]
    for x in xs
        x > 1 && push!(xs, 0)
    end
    return xs
end

const QUEUE = Int[]

function drain()
    for x in QUEUE
        x > 0 && popfirst!(QUEUE)
    end
    return nothing
end

halve!(xs::Vector{Int}) = (xs .÷= 2; xs)

function shrink!(xs::Vector{Int})
    for x in xs
        x > 10 && halve!(xs)
    end
    return xs
end

function shift!(counts::AbstractDict{Int, Int})
    for (key, count) in counts
        counts[key + 1] = count
    end
    return counts
end

end
