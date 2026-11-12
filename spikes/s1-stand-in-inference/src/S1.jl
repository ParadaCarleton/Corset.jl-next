"Spike S1: stand-in inference over package methods."
module S1
include("StandIns.jl")
include("Signatures.jl")
include("Scan.jl")
using .StandIns, .Signatures, .Scan
export StandIns, Signatures, Scan
end
