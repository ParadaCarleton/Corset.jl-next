# runic: off
module StatefulIteratePositive

function head(s::Iterators.Stateful)
    x, _ = iterate(s)
    return x
end

following(s::Iterators.Stateful{Vector{Int}}) = Base.iterate(s, nothing)

end
