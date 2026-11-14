# runic: off
"""Names reached through bare `using`."""
module ImplicitImportPositive

using LinearAlgebra: LinearAlgebra, dot, norm
using Dates, Base.Iterators
using Unicode: Unicode

include("geometry.jl")
include("format.jl")
area(sides::Vector{Float64}) = norm(sides) * 2
today_year() = year(today())
pairs_of(lists::Vector) = collect(flatten(lists))
module_name() = LinearAlgebra

module Inner
    using LinearAlgebra: LinearAlgebra, normalize
    unit(vector::Vector{Float64}) = normalize(vector)
end

end
