# runic: off
"""Imports in file that uses them, shared imports, and imports other rules cover."""
module MisplacedImportNegative

using LinearAlgebra: norm
using LinearAlgebra: dot
using LinearAlgebra: det
using Printf: @printf
using Base.Iterators: take
using Dates
import Unicode: normalize as clean
include("shared.jl")
include("other.jl")
include("local.jl")

area(sides::Vector{Float64}) = norm(sides)

# Import of submodule: root module uses of same name do not count.
module Sub
    using LinearAlgebra: tr
end

# Dynamic `include`: ExplicitImports.jl cannot analyze module.
module Dynamic
    using LinearAlgebra: cross
    include("static.jl")
    include(string("dyn", "amic.jl"))
end

end
