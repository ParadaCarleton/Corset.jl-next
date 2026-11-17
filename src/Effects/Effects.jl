"""
`effects` stage: effect summary of each package method from its inference units (`effects.md`, Effects engine).

Engine builds SSA IR before inlining for each unit and each instance it reaches, then solves call graph bottom-up.
Summary holds writes, reads and result aliases by caller place, with doubt: definite, `possible`, or blind spot.
"""
module Effects

using EnumX: @enumx
using Graphs: SimpleDiGraph, add_edge!, condensation, inneighbors, strongly_connected_components, topological_sort_by_dfs
using Moshi.Data: @data
using Moshi.Derive: @derive
using Moshi.Match: @match
using ..Facts: Facts, PackageFacts, EffectsFacts, MethodEffects, Access, BlindAccess, Step, Root, Place, PATH_DEPTH, BlindSpot, Confidence, Span
using ..Inference: TypedCode, Units, Journal, Record, record!, method_label

const CC = Core.Compiler

include("ir.jl")
include("model.jl")
include("calls.jl")
include("flow.jl")
include("transfer.jl")
include("summary.jl")
include("solve.jl")
include("verdict.jl")

end
