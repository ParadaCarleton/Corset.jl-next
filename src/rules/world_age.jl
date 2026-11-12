"""
`world-age` (F63): function defined by `eval` called in same world.

## Description
Reports call to function that `eval` or `@eval` defines earlier in same function body.

## Rationale
Running function sees only methods that existed when it started. Call right after `eval` throws `MethodError`, or runs old method.

## Example
```julia
function setup()
    @eval helper() = 1
    return helper()
end
```

## Alternative
```julia
function setup()
    @eval helper() = 1
    return Base.invokelatest(helper)
end
```

## Limitations
Fix is `manual` when call passes keywords.
"""
module WorldAge

using ...Facts

const NAME = Symbol("world-age")
"""Name defined by function definition inside `node`, which evaluates code; `nothing` when none."""
function evaluated_definition(node)::Union{Nothing, String}
    is_eval = (kind_name(node) == "macrocall" && leaf_value(children_of(node)[1]) == "@eval") || call_head(node) == "eval"
    is_eval || return nothing
    for inner in descendants(node)
        kind_name(inner) == "function" || continue
        signature = children_of(inner)[1]
        while kind_name(signature) in ("where", "::")
            signature = children_of(signature)[1]
        end
        kind_name(signature) == "call" && return call_head(signature)
    end
    return nothing
end

"""Fix wrapping call `node` in `Base.invokelatest`; manual when call passes keywords."""
function latest_fix(file::SyntaxFile, node)::Fix
    parts = children_of(node)
    any(part -> kind_name(part) == "parameters", parts) && return manual_fix("call through `Base.invokelatest`")
    return replace_fix(file, node, "Base.invokelatest(" * join((source(file, part) for part in parts), ", ") * ")", Tier.safe)
end

"""Findings for calls in same function body after `eval` defines called function."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, definition in forms(file, "function")
        body = children_of(definition)[end]
        kind_name(body) == "block" || continue
        defined = Dict{String, Any}()
        for statement in children_of(body)
            name = evaluated_definition(statement)
            isnothing(name) || (defined[name] = statement; continue)
            for node in descendants(statement)
                call_head(node) in keys(defined) || continue
                push!(
                    found, finding(
                        NAME, file, node; kind = :same_world_call, confidence = Confidence.definite,
                        message = "`$(call_head(node))` is called in world older than its definition",
                        label = "MethodError: method too new", why = "running function keeps world it started in; `eval` adds method to newer world",
                        fix = latest_fix(file, node),
                        causes = [Label(span(file, defined[call_head(node)]), "defined by `eval` here")],
                    )
                )
            end
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [63], Stage.syntax, run)

end
