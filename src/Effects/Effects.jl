"""`effects` stage by name trust (`effects.md`, Name trust): per-unit records and method facts."""
module Effects

using Moshi.Match: @match
using ..Facts: Access, UnguardedHold, LoopWrite, SelfAlias, StatefulReuse, Callee, methods_callee, callee_methods, CallFact, MethodEffects, EffectsFacts, PackageFacts, Place, PlaceSteps, place_root, root_global, place_text, Root, Step, NO_STEPS, PATH_DEPTH, EffectKind, Confidence, BlindSpot, Span
using ..Inference: TypedCode, Units, called, holds_stand_in, serialized

const CC = Core.Compiler

include("ir.jl")
include("records.jl")
include("tables.jl")
include("names.jl")
include("closures.jl")
include("loops.jl")
include("aliasing.jl")
include("reuse.jl")
include("units.jl")

end
