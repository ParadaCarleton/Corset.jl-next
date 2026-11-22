# runic: off
module StatefulIterateNegative

head(s::Iterators.Stateful) = popfirst!(s)

# `for` loop consumes iterator by design.
function total(s::Iterators.Stateful{Vector{Int}})
    sum = 0
    for x in s
        sum += x
    end
    return sum
end

# Array iteration writes nothing.
first_pair(xs::Vector{Int}) = iterate(xs)

end
