# ==> src/UnusedImportPositive.jl
# runic: off
"""Imports with names module never uses."""
module UnusedImportPositive

using LinearAlgebra: norm, dot  # vector math
using Printf: @sprintf
import Dates
import Unicode, Base64
using Printf: Printf
using LinearAlgebra: tr; const ONE = 1
using LinearAlgebra: cross #= note =# ; const TWO = 2
using UUIDs: uuid4  # only import that loads UUIDs
include("geometry.jl")

area(sides::Vector{Float64}) = norm(sides) + dot(sides, sides)
label(value::Float64) = @sprintf("%.2f", value)
encoded(text::String) = Base64.base64encode(text)

module Inner
end

end
# ==> src/geometry.jl
# runic: off
scale(vector::Vector{Float64}) = 2 .* vector
