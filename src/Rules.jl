"""Rule registry: one pure function per rule. Each rule file imports only `Facts`."""
module Rules

using ..Facts: RuleEntry

include("rules/ambiguous_concat.jl")
include("rules/annotation.jl")
include("rules/approx_zero.jl")
include("rules/baked_state.jl")
include("rules/bracketed_range.jl")
include("rules/broad_catch.jl")
include("rules/c_type.jl")
include("rules/docstring.jl")
include("rules/double_include.jl")
include("rules/duplicate_statement.jl")
include("rules/field_prefix.jl")
include("rules/file_length.jl")
include("rules/inference_dependent.jl")
include("rules/juxtaposition.jl")
include("rules/mixed_return.jl")
include("rules/module_inception.jl")
include("rules/nan_compare.jl")
include("rules/one_letter.jl")
include("rules/orphan_task.jl")
include("rules/repeated_concat.jl")
include("rules/threadid_buffer.jl")
include("rules/unguarded_release.jl")
include("rules/unreachable.jl")
include("rules/untyped_empty.jl")
include("rules/unused_literal.jl")
include("rules/where_binding.jl")
include("rules/wide_struct.jl")
include("rules/world_age.jl")

"""Every rule, in name order (test enforces order)."""
const REGISTRY = RuleEntry[
    AmbiguousConcat.ENTRY,
    Annotation.ENTRY,
    ApproxZero.ENTRY,
    BakedState.ENTRY,
    BracketedRange.ENTRY,
    BroadCatch.ENTRY,
    CType.ENTRY,
    Docstring.ENTRY,
    DoubleInclude.ENTRY,
    DuplicateStatement.ENTRY,
    FieldPrefix.ENTRY,
    FileLength.ENTRY,
    InferenceDependent.ENTRY,
    Juxtaposition.ENTRY,
    MixedReturn.ENTRY,
    ModuleInception.ENTRY,
    NanCompare.ENTRY,
    OneLetter.ENTRY,
    OrphanTask.ENTRY,
    RepeatedConcat.ENTRY,
    ThreadidBuffer.ENTRY,
    UnguardedRelease.ENTRY,
    Unreachable.ENTRY,
    UntypedEmpty.ENTRY,
    UnusedLiteral.ENTRY,
    WhereBinding.ENTRY,
    WideStruct.ENTRY,
    WorldAge.ENTRY,
]

"""Registry entry named `name`; throws for unknown rule."""
function entry(name::Symbol)::RuleEntry
    index = findfirst(entry -> entry.name == name, REGISTRY)
    isnothing(index) && throw(ArgumentError("unknown rule: $name"))
    return REGISTRY[index]
end

end
