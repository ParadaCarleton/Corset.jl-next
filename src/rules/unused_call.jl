"""
`unused-call` (F54): call has no effect, and code drops its result.

## Description
Reports call statement whose value Julia drops, when compiler proves call writes nothing caller sees (`effect_free`),
cannot throw (`nothrow`) and terminates. Name trust never proves absence of writes, so rule needs compiler proof.
Call that may throw passes: discarded `parse(Int, text)` validates input.
Value assigned to name no code reads is not discarded statement: unused variable rule covers it.

## Rationale
Such call does nothing. Usually code forgot to assign result, or called copying function in place of mutating one.

## Example
```julia
function cap!(levels::Vector{Float64}, high::Float64)
    for index in eachindex(levels)
        min(levels[index], high)
    end
    return levels
end
```

## Alternative
```julia
function cap!(levels::Vector{Float64}, high::Float64)
    for index in eachindex(levels)
        levels[index] = min(levels[index], high)
    end
    return levels
end
```

## Limitations
Finding is `definite` when inference covers every argument type method declares and no stand-in cuts path; else `possible`.
Call whose operand types are not concrete joins effects of methods loaded now; operand type that holds stand-in gives
effects of stand-in only. Both give `possible`: other types can give call effect.
`@assume_effects` claim of callee voids proof: compiler trusts claim without check.
Rule skips call it cannot tie to source statement: call lowering inserts or copies (`finally`), call inside macro
call. Such call without effect goes to coverage line.
`Core.donotdelete` passes: it keeps value alive for benchmarks.
Fix is `manual`: rule cannot tell missing assignment from leftover statement.
"""
module UnusedCall

using ...Facts

const NAME = Symbol("unused-call")

"""Call statements of `files` whose value Julia drops (`discarded`), with their file, by path and byte range."""
function statements(files::AbstractVector{SyntaxFile})::Dict{Tuple{String, Int, Int}, Tuple{SyntaxFile, SyntaxNode}}
    found = Dict{Tuple{String, Int, Int}, Tuple{SyntaxFile, SyntaxNode}}()
    for file in files, kind in ("call", "juxtapose"), node in forms(file, kind)
        discarded(node) || continue
        bounds = span(file, node)
        found[(file.path, bounds.first_byte, bounds.last_byte)] = (file, node)
    end
    return found
end

"""Whether call `node` of `file` names function `name`, module prefix dropped; product `2x` calls `*`."""
function names_callee(file::SyntaxFile, node::SyntaxNode, name::String)::Bool
    kind_name(node) == "juxtapose" && return name == "*"
    return last(split(source(file, callee_node(node)), '.')) == name
end

"""
Findings for each call statement of package method that has no effect and whose value Julia drops. Call span must
be exact and spell discarded statement with same callee: lowering gives calls it inserts span of nearby statement.
"""
function findings(facts::FactSet)::Vector{Finding}
    effects = facts.effects
    isnothing(effects) && return Finding[]
    found, sources = Finding[], statements(facts.files)
    for method in effects.methods, call in method.calls
        no_effect(call) && call.span.precision == Precision.exact || continue
        name = callee_name(call.callee)
        site = get(sources, (call.span.file, call.span.first_byte, call.span.last_byte), nothing)
        (isnothing(name) || isnothing(site) || !names_callee(site..., name)) && continue
        sure = method.complete && !call.open_dispatch && !call.stand_in
        push!(
            found, Finding(
                NAME, :no_effect, sure ? Confidence.definite : Confidence.possible, "call to `$name` has no effect",
                Label(call.span, "result dropped; call writes nothing and cannot throw"), Label[],
                "call does nothing but compute value, and code drops value; assignment is probably missing",
                manual_fix("assign result, or delete call"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [54], Stage.effects, findings)

end
