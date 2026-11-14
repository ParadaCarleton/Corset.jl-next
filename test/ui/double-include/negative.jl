# runic: off
include("geometry.jl")
include("solvers.jl")
include(joinpath("ext", "plots.jl"))
include(joinpath("ext", "tables", "plots.jl"))
include(name)
include(name)

# Branch no supported Julia runs includes nothing.
@static if !isdefined(Base, :get_extension)
    include("geometry.jl")
end
