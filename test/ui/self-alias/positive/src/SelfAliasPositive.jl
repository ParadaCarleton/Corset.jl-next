# runic: off
module SelfAliasPositive

struct Ledger
    amounts::Vector{Int}
end

# `sum!` fills output with zero before it reads input.
function total_rows!(totals::Vector{Float64})
    sum!(totals, totals)
    return totals
end

# Two loads of one field give one array.
function settle!(ledger::Ledger)
    prod!(ledger.amounts, ledger.amounts)
    return ledger
end

# `splice!` copies replacement after resize.
function repeat_front!(xs::Vector{Int})
    splice!(xs, 1:2, xs)
    return xs
end

# Narrowed argument stays one array.
function flag_any!(flags::Union{Nothing, Vector{Bool}})
    isnothing(flags) && return nothing
    any!(flags, flags)
    return flags
end

# Overlapping views: `map!` reads elements it already wrote.
function shift_right!(values::Vector{Float64})
    map!(identity, view(values, 2:lastindex(values)), view(values, 1:(lastindex(values) - 1)))
    return values
end

# View of output passed as input.
function running_total!(xs::Vector{Int})
    accumulate!(+, view(xs, 2:lastindex(xs)), xs)
    return xs
end

end
