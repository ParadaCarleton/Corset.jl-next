# runic: off
"""Imports module uses: call, method extension, `export`, `public`, `@eval`, qualified module name."""
module UnusedImportNegative

using LinearAlgebra: norm, dot, det, tr
import Base: show, +, ==
import Dates
using Printf: @sprintf
using Markdown: @md_str
import Unicode: normalize as clean
using Base64
using Base64: var"base64encode", base64decode
export norm
public dot
include("other.jl")

struct Point end
show(io::IO, ::Point) = print(io, "Point")
+(::Point, ::Point) = Point()
==(::Point, ::Point) = true
@eval twice(matrix::Matrix{Float64}) = 2 * $(det)(matrix)
stamp() = Dates.year(Dates.now())

# Dynamic `include`: ExplicitImports.jl cannot analyze module.
module Dynamic
    using LinearAlgebra: cross
    include(string("dyn", "amic.jl"))
end

end
