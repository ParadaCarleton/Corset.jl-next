# runic: off
module ImpureLambdaPositive

const CALLS = Ref(0)

# Predicate records each element: result depends on call order of `filter`.
function first_seen(items::Vector{Int})
    seen = Set{Int}()
    return filter(item -> item in seen ? false : (push!(seen, item); true), items)
end

function counted(items::Vector{Float64})
    calls = Ref(0)
    doubled = map(item -> (calls[] += 1; 2item), items)
    return doubled, calls[]
end

sorted_logged(log::Vector{Int}, items::Vector{Int}) = sort(items; by = item -> (push!(log, item); item))

total(items::Vector{Float64}) = sum(item -> (CALLS[] += 1; item), items)

function any_large(log::Vector{Int}, items::Vector{Int})
    return any(items) do item
        push!(log, item)
        item > 10
    end
end

end
