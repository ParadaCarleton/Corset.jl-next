# runic: off
"""Fixture of `temporary-array`: arrays that method builds only for one reduction."""
module TemporaryArrayPositive

total_size(x::Vector{Float64}) = sum(abs.(x))

largest_square(x::Vector{Int}) = maximum([v^2 for v in x])

count_negative(x::Vector{Float64}) = count(collect(v < 0 for v in x))

ranged_total(n::Int) = sum(collect(1:n))

# Keyword argument before array: fix swaps array argument alone.
keyword_first(x::Vector{Float64}) = sum(init = 0.0, abs.(x))

folded_squares(x::Vector{Int}) = reduce(+, [v^2 for v in x])

# Function and source keep array, so `dims` works.
abs_columns(A::Matrix{Float64}) = sum(abs.(A); dims = 1)

# Infix broadcast has no function to pass, `reduce` takes no source after function, and `any` stops early: manual.
squares_total(x::Vector{Float64}) = sum(x .^ 2)

folded(x::Vector{Float64}) = reduce(+, abs.(x))

any_negative(x::Vector{Float64}) = any([v < 0 for v in x])

# Generator cannot keep dimensions or reverse.
square_columns(A::Matrix{Int}) = sum([v^2 for v in A]; dims = 1)

right_fold(x::Vector{Float64}) = foldr(+, [v^2 for v in x])

end
