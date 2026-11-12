"""Check registry: one pure function per check. Each check file imports only `Facts`."""
module Checks

using ..Facts: CheckEntry

include("checks/approx_zero.jl")
include("checks/one_based_range.jl")
include("checks/shared_fill.jl")
include("checks/threadid_buffer.jl")
include("checks/untyped_empty.jl")

"""Every check, in name order."""
const REGISTRY = sort!(
    CheckEntry[ApproxZero.ENTRY, OneBasedRange.ENTRY, SharedFill.ENTRY, ThreadidBuffer.ENTRY, UntypedEmpty.ENTRY];
    by = entry -> entry.name,
)

"""Registry entry named `name`; throws for unknown check."""
function entry(name::Symbol)::CheckEntry
    index = findfirst(entry -> entry.name == name, REGISTRY)
    isnothing(index) && throw(ArgumentError("unknown check: $name"))
    return REGISTRY[index]
end

end
