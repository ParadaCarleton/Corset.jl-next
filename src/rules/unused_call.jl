"""
`unused-call` (F54): call has no effect, and code drops its result.

## Description
Reports call statement whose value Julia drops, when call writes nothing of any kind, cannot throw and terminates.
Writes come from callee summaries of `effects` stage; compiler effects give `nothrow` and `terminates`.
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
Call whose verdict joins methods loaded now, or whose operand type holds stand-in, gives `possible`: other types can give it effect.
Rule skips call it cannot tie to source statement: call lowering inserts, call inside macro call.
`Core.donotdelete` passes: it keeps value alive for benchmarks.
Fix is `manual`: rule cannot tell missing assignment from leftover statement.
"""
module UnusedCall

using ...Facts

const NAME = Symbol("unused-call")

"""Whether `call` drops its result, writes nothing, cannot throw and terminates; `Core.donotdelete` is exempt."""
unused(call::CallFact)::Bool =
    !call.used && isempty(call.kinds) && !call.throws && call.terminates && call.callee != Callee.Builtin(Core.donotdelete)

"""Call statements of `files` whose value Julia drops (`discarded`), with their file, by path and byte range."""
function statements(files::Vector{SyntaxFile})::Dict{Tuple{String, Int, Int}, Tuple{SyntaxFile, SyntaxNode}}
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
        unused(call) && call.span.precision == Precision.exact || continue
        name = callee_name(call.callee)
        site = get(sources, (call.span.file, call.span.first_byte, call.span.last_byte), nothing)
        (isnothing(name) || isnothing(site) || !names_callee(site..., name)) && continue
        sure = method.complete && !call.closed_world && !call.stand_in
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
