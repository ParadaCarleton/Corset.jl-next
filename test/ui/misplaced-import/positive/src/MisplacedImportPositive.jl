# runic: off
"""Imports placed apart from only file that uses them."""
module MisplacedImportPositive

using LinearAlgebra: norm, dot  # vector math
import Dates
using Printf: @sprintf; const DIGITS = 2
const ZONE = 0; using Unicode: graphemes
include("solve.jl")
include("clock.jl")
include("helpers.jl")

clean(text::String) = normalize(text)

module Inner
    using LinearAlgebra: cross
    include("inner.jl")
    trace_of(matrix::Matrix{Float64}) = tr(matrix)
end

module Tiny; include("tiny.jl"); stamp() = today(); end

end
