# ==> src/ImplicitImportPositive.jl
# runic: off
"""Names reached through bare `using`."""
module ImplicitImportPositive

using LinearAlgebra: LinearAlgebra, dot, norm
using Dates, Base.Iterators
using Unicode: Unicode
using Markdown: Markdown, @md_str

include("geometry.jl")
include("format.jl")
area(sides::Vector{Float64}) = norm(sides) * 2
today_year() = year(today())
pairs_of(lists::Vector) = collect(flatten(lists))
module_name() = LinearAlgebra
note() = md"*string macro*"

module Inner
    using LinearAlgebra: LinearAlgebra, normalize
    unit(vector::Vector{Float64}) = normalize(vector)
end

# Sibling modules share inner name; each finding names own statement.
module Left
    module Shapes
        using LinearAlgebra: LinearAlgebra
    end
end
module Right
    module Shapes
        using LinearAlgebra: LinearAlgebra, normalize
        scaled(vector::Vector{Float64}) = normalize(vector)
    end
end

end
# ==> src/format.jl
using Printf: Printf, @sprintf
label(value::Float64) = @sprintf("%.2f", value)
