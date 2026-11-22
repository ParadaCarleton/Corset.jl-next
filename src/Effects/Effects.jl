"""Per-unit effects facts and inference IR."""
module Effects

using Moshi.Match: @match
using ..Facts: Access, UnguardedHold, Callee, methods_callee, CallFact, Place, BlindSpot, Span
using ..Inference: serialized

const CC = Core.Compiler

include("ir.jl")
include("records.jl")

end
