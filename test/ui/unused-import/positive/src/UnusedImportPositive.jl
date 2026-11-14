# runic: off
"""Imports with names module never uses."""
module UnusedImportPositive

using LinearAlgebra: norm, det, dot, kron  # vector math
using Printf: @printf, @sprintf
import Dates
import Unicode, Base64
using LinearAlgebra: tr; const ONE = 1
using LinearAlgebra: cross #= note =# ; const TWO = 2
include("geometry.jl")

area(sides::Vector{Float64}) = norm(sides) + dot(sides, sides)
label(value::Float64) = @sprintf("%.2f", value)
encoded(text::String) = Base64.base64encode(text)

module Inner
    using LinearAlgebra: lu
end

end
