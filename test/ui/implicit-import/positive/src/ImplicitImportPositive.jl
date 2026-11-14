# runic: off
"""Names reached through bare `using`."""
module ImplicitImportPositive

using LinearAlgebra
using Dates, Base.Iterators
using Unicode
using Markdown

include("geometry.jl")
include("format.jl")
area(sides::Vector{Float64}) = norm(sides) * 2
today_year() = year(today())
pairs_of(lists::Vector) = collect(flatten(lists))
module_name() = LinearAlgebra
note() = md"*string macro*"

module Inner
    using LinearAlgebra
    unit(vector::Vector{Float64}) = normalize(vector)
end

end
