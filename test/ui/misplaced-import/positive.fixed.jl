# ==> src/MisplacedImportPositive.jl
# runic: off
"""Imports placed apart from only file that uses them."""
module MisplacedImportPositive

using Unicode: normalize
using Printf: @sprintf; const DIGITS = 2
const ZONE = 0; using Unicode: graphemes
include("solve.jl")
include("clock.jl")
include("helpers.jl")

clean(text::String) = normalize(text)

module Inner
    using LinearAlgebra: tr
    include("inner.jl")
    trace_of(matrix::Matrix{Float64}) = tr(matrix)
end

module Tiny; include("tiny.jl"); stamp() = today(); end

end
# ==> src/clock.jl
import Dates
now_year() = Dates.year(Dates.now())
label(value::Float64) = @sprintf("%.2f", value)

# Local, key and field named like imports are no uses.
function scaled()
    norm = 2.0
    return norm * 3
end
const WEIGHTS = (; dot = 1.0)
const UNIT_WEIGHT = WEIGHTS.dot
struct Product
    dot::Float64
end
# ==> src/helpers.jl
shout(text::String) = uppercase(text)
letters(text::String) = collect(graphemes(text))
# ==> src/inner.jl
using LinearAlgebra: cross
turn(left::Vector{Float64}, right::Vector{Float64}) = cross(left, right)
# ==> src/solve.jl
# Solvers.
using LinearAlgebra: norm, dot  # vector math
solve(vector::Vector{Float64}) = norm(vector) / dot(vector, vector)
const UNIT = dot([1.0], [1.0])
