# runic: off
module IterationMutationNegative

mutable struct Box
    value::Int
end

# Element write: collection keeps its size.
function zero_all!(boxes::Vector{Box})
    for box in boxes
        box.value = 0
    end
    return boxes
end

# Array element replacement keeps every index valid.
function clamp_all!(xs::Vector{Int})
    for (index, x) in enumerate(xs)
        xs[index] = min(x, 10)
    end
    return xs
end

# Base deletes from `Dict` while iterating it.
function drop_negative!(counts::Dict{String, Int})
    for name in keys(counts)
        counts[name] < 0 && delete!(counts, name)
    end
    return counts
end

# Loop iterates copy of keys.
function drop_empty!(groups::AbstractDict{String, Vector{Int}})
    for name in collect(keys(groups))
        isempty(groups[name]) && delete!(groups, name)
    end
    return groups
end

# Other collection.
function copy_into!(target::Vector{Int}, source::Vector{Int})
    for x in source
        push!(target, x)
    end
    return target
end

# Write after loop ends.
function append_total!(xs::Vector{Int})
    total = 0
    for x in xs
        total += x
    end
    push!(xs, total)
    return xs
end

end
