# runic: off
"""Explicit imports, and bare `using` of Base and own modules."""
module ImplicitImportNegative

using LinearAlgebra: LinearAlgebra, norm
import Dates
using Base.Iterators

area(sides::Vector{Float64}) = norm(sides) * 2
today_year() = Dates.year(Dates.today())
pairs_of(lists::Vector) = collect(flatten(lists))
helper(value::Int) = value

# Dynamic `include`: ExplicitImports.jl cannot analyze module.
module Dynamic
    include(string("dyn", "amic.jl"))
end

module Inner
    using ..ImplicitImportNegative
    twice(value::Int) = 2 * ImplicitImportNegative.helper(value)
end

end
