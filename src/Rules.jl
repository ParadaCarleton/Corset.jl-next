"""Rule registry: one pure function per rule. Each rule file imports only `Facts`."""
module Rules

using ..Facts: RuleEntry

include("rules/ambiguous_concat.jl")
include("rules/annotation.jl")
include("rules/approx_zero.jl")
include("rules/baked_state.jl")
include("rules/banned.jl")
include("rules/bracketed_range.jl")
include("rules/broad_catch.jl")
include("rules/c_type.jl")
include("rules/closed_struct.jl")
include("rules/docstring.jl")
include("rules/double_include.jl")
include("rules/duplicate_statement.jl")
include("rules/field_prefix.jl")
include("rules/file_length.jl")
include("rules/inference_dependent.jl")
include("rules/invariant_parameter.jl")
include("rules/iterator_traits.jl")
include("rules/juxtaposition.jl")
include("rules/method_overwrite.jl")
include("rules/missing_interface.jl")
include("rules/mixed_return.jl")
include("rules/module_inception.jl")
include("rules/nan_compare.jl")
include("rules/one_letter.jl")
include("rules/operator_consistency.jl")
include("rules/orphan_task.jl")
include("rules/pinned_task.jl")
include("rules/process_state.jl")
include("rules/repeated_concat.jl")
include("rules/shadowed_base.jl")
include("rules/threadid_buffer.jl")
include("rules/unguarded_release.jl")
include("rules/unreachable.jl")
include("rules/untested_extension.jl")
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
    Banned.ENTRY,
    BracketedRange.ENTRY,
    BroadCatch.ENTRY,
    CType.ENTRY,
    ClosedStruct.ENTRY,
    Docstring.ENTRY,
    DoubleInclude.ENTRY,
    DuplicateStatement.ENTRY,
    FieldPrefix.ENTRY,
    FileLength.ENTRY,
    InferenceDependent.ENTRY,
    InvariantParameter.ENTRY,
    IteratorTraits.ENTRY,
    Juxtaposition.ENTRY,
    MethodOverwrite.ENTRY,
    MissingInterface.ENTRY,
    MixedReturn.ENTRY,
    ModuleInception.ENTRY,
    NanCompare.ENTRY,
    OneLetter.ENTRY,
    OperatorConsistency.ENTRY,
    OrphanTask.ENTRY,
    PinnedTask.ENTRY,
    ProcessState.ENTRY,
    RepeatedConcat.ENTRY,
    ShadowedBase.ENTRY,
    ThreadidBuffer.ENTRY,
    UnguardedRelease.ENTRY,
    Unreachable.ENTRY,
    UntestedExtension.ENTRY,
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
