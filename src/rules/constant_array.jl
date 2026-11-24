"""
`constant-array` (F39): filled array that method never writes allocates every element.

## Description
Reports `zeros`, `ones`, `fill`, `trues` or `falses` array of package method that method only reads: no write,
resize, escape or `φ` join. Allocations and their events come from `lifecycle` stage.
Fix swaps call for FillArrays.jl type and imports it above first statement of module code.

## Rationale
Array that holds one value in every element needs no memory per element. FillArrays.jl `Zeros`, `Ones`, `Fill`,
`Trues` and `Falses` store value and axes only, and many functions take shortcuts on them (`sum`, `*`).

## Example
```julia
weighted(x::Vector{Float64}) = x' * ones(length(x))
```

## Alternative
```julia
using FillArrays: Ones
weighted(x::Vector{Float64}) = x' * Ones(length(x))
```

## Limitations
Fix tier is `likely`: callee that requires `Array` rejects lazy array, and package must add FillArrays.jl to its
dependencies. Call that inference cannot place, module that binds same name to other value, and one-line module get
`manual` fix.
"""
module ConstantArray

using ...Facts

const NAME = Symbol("constant-array")

"""Event kinds after which array holds other values, or uses stay unseen."""
const CHANGES = (ArrayEventKind.write, ArrayEventKind.resize, ArrayEventKind.escape, ArrayEventKind.joined)

"""FillArrays.jl type that replaces each Base function of filled array."""
const LAZY = Dict("zeros" => "Zeros", "ones" => "Ones", "fill" => "Fill", "trues" => "Trues", "falses" => "Falses")

"""Whether `array` is filled array that method reads and never changes."""
function constant(array::ArrayLife)::Bool
    array.kind == AllocationKind.filled || return false
    any(event -> event.kind in CHANGES, array.events) && return false
    return any(event -> event.kind == ArrayEventKind.read, array.events)
end

"""
Fix that swaps filled-array call at `site` for FillArrays.jl type, and imports type above module code when module
`mod` lacks it. `manual` when `site` is no call node of `files`, or when `mod` binds type name to other value.
"""
function lazy_fix(files::AbstractDict{String, SyntaxFile}, site::Span, mod::Module)::Fix
    manual = manual_fix("use FillArrays.jl `Zeros`, `Ones`, `Fill`, `Trues` or `Falses`, and add FillArrays.jl to package dependencies")
    file = get(files, site.file, nothing)
    calls = isnothing(file) ? SyntaxNode[] : [node for node in forms(file, "call") if span(file, node) == site && haskey(LAZY, call_head(node))]
    isempty(calls) && return manual
    call = first(calls)
    lazy = LAZY[something(call_head(call))]
    swap = Edit(span(file, callee_node(call)), lazy)
    if isdefined(mod, Symbol(lazy))
        # Package type of same name would take swapped call.
        nameof(which(mod, Symbol(lazy))) == :FillArrays || return manual
        return Fix("replace with FillArrays.jl `$lazy`", [swap], Tier.likely)
    end
    imported = module_top_insertion(file, site.first_byte, "using FillArrays: $lazy")
    isnothing(imported) && return manual
    return Fix("replace with FillArrays.jl `$lazy` and import it; add FillArrays.jl to package dependencies", [imported, swap], Tier.likely)
end

"""Findings for each filled array of package method that method only reads."""
function findings(facts::FactSet)::Vector{Finding}
    lifecycle = facts.lifecycle
    isnothing(lifecycle) && return Finding[]
    files, found = Dict(file.path => file for file in facts.files), Finding[]
    for method in lifecycle.methods, array in method.arrays
        constant(array) || continue
        read = first(event for event in array.events if event.kind == ArrayEventKind.read)
        push!(
            found, Finding(
                NAME, :constant_array, Confidence.definite, "array holds one value in every element but allocates each",
                Label(array.site, "allocates every element here"), [Label(read.span, "only reads it")],
                "constant array needs no memory per element", lazy_fix(files, array.site, method.site.method.module),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.performance, [39], Stage.lifecycle, findings)

end
