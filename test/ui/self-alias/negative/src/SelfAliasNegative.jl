# runic: off
module SelfAliasNegative

# Base docstring calls `map!(f, A, A)` equivalent of `map!(f, A)`.
function square_all!(values::Vector{Float64})
    map!(abs2, values, values)
    return values
end

# Scan reads each input element before it writes it.
function running_sum!(values::Vector{Float64})
    cumsum!(values, values)
    return values
end

# `copyto!` unaliases overlapping input.
function shift_copy!(xs::Vector{Int})
    copyto!(view(xs, 2:lastindex(xs)), view(xs, 1:(lastindex(xs) - 1)))
    return xs
end

# `setindex!` unaliases overlapping input.
function shift_assign!(xs::Vector{Int})
    xs[2:end] = view(xs, 1:(lastindex(xs) - 1))
    return xs
end

# Output and input are other arrays.
function row_totals!(totals::Vector{Float64}, matrix::Matrix{Float64})
    sum!(totals, matrix)
    return totals
end

# `append!` gives no aliasing warning.
function double!(xs::Vector{Int})
    append!(xs, xs)
    return xs
end

end
