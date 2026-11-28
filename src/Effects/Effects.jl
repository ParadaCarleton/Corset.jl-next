"""
`effects` stage (`effects.md`): engine verdicts (`Summaries`) give method writes, reads and result aliases; name tier
gives per-unit records and other method facts.
"""
module Effects

using Moshi.Match: @match
using ..Facts: argument_type, subject_position, RESIZE_FUNCTIONS, Access, UnguardedHold, LoopWrite, SelfAlias, StatefulReuse, UnprovenIndex, IndexContract, IndexSource, OperandIndex, ArrayOperand, IndexCall, IndexFacts, AllocationKind, ArrayEventKind, Coverage, ArrayPath, ArrayEvent, Rebind, ArrayLife, Callee, methods_callee, callee_methods, CallFact, no_effect, MethodEffects, EffectsFacts, PackageFacts, Place, PlaceSteps, place_root, root_global, place_text, Root, Step, NO_STEPS, PATH_DEPTH, EffectKind, Confidence, BlindSpot, Span, Precision, SyntaxFile
using ..Inference: Inference, TypedCode, Units, called, holds_stand_in, serialized
using ..Timings: Sink, timed

const CC = Core.Compiler

# Engine reads Base function contracts of name tier (`IO_FUNCTIONS`).
include("tables.jl")
include("engine/Summaries.jl")
using .Summaries: Summaries, stored_callee, loaded_callee, merge_callees, ordered_records

include("ir.jl")
include("records.jl")
include("names.jl")
include("closures.jl")
include("loops.jl")
include("aliasing.jl")
include("reuse.jl")
include("indices.jl")
include("balance.jl")
include("arrays.jl")
include("units.jl")

end
