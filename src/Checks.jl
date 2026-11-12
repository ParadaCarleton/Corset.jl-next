"""Check registry: one pure function per check. Each check file imports only `Facts`."""
module Checks

using ..Facts: CheckEntry

include("checks/ambiguous_concat.jl")
include("checks/approx_zero.jl")
include("checks/bracketed_range.jl")
include("checks/broad_catch.jl")
include("checks/c_type.jl")
include("checks/docstring.jl")
include("checks/double_include.jl")
include("checks/duplicate_statement.jl")
include("checks/file_length.jl")
include("checks/inference_dependent.jl")
include("checks/juxtaposition.jl")
include("checks/loop_order.jl")
include("checks/mixed_return.jl")
include("checks/one_based_range.jl")
include("checks/one_letter.jl")
include("checks/orphan_task.jl")
include("checks/quadratic.jl")
include("checks/shared_fill.jl")
include("checks/struct_shape.jl")
include("checks/threadid_buffer.jl")
include("checks/untyped_empty.jl")
include("checks/where_binding.jl")
include("checks/world_age.jl")

"""Every check, in name order (test enforces order)."""
const REGISTRY = CheckEntry[AmbiguousConcat.ENTRY, ApproxZero.ENTRY, BracketedRange.ENTRY, BroadCatch.ENTRY, CType.ENTRY, Docstring.ENTRY, DoubleInclude.ENTRY, DuplicateStatement.ENTRY, StructShape.PREFIX, FileLength.ENTRY, InferenceDependent.ENTRY, Juxtaposition.ENTRY, LoopOrder.ENTRY, MixedReturn.ENTRY, OneBasedRange.ENTRY, OneLetter.ENTRY, OrphanTask.ENTRY, Quadratic.ENTRY, SharedFill.ENTRY, ThreadidBuffer.ENTRY, UntypedEmpty.ENTRY, WhereBinding.ENTRY, StructShape.WIDE, WorldAge.ENTRY]

"""Registry entry named `name`; throws for unknown check."""
function entry(name::Symbol)::CheckEntry
    index = findfirst(entry -> entry.name == name, REGISTRY)
    isnothing(index) && throw(ArgumentError("unknown check: $name"))
    return REGISTRY[index]
end

end
