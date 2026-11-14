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

`Core.eval(M, …)` and `@eval M …` define in module `M`: only call written `M.f(…)` reaches that definition.

## Limitations
Fix is `manual` when call passes keywords.
"""
module WorldAge

using ...Facts

const NAME = Symbol("world-age")
"""Module eval `node` defines in, as written: `M` in `Core.eval(M, ex)` and `@eval M ex`; `nothing` for current module."""
function eval_target(file::SyntaxFile, node::SyntaxNode)::Union{Nothing, String}
    pieces = children_of(node)
    length(pieces) == 3 || return nothing
    target = source(file, pieces[2])
    return target == "@__MODULE__" ? nothing : target
end

"""
Name call reaches function definition inside `node` by, which evaluates code: Base-normalized name in current module,
`M.f` in other module `M`. `nothing` when none.
"""
function evaluated_definition(file::SyntaxFile, node::SyntaxNode)::Union{Nothing, String}
    is_eval = base_macro(node) == "@eval" || call_head(node) == "eval"
    is_eval || return nothing
    target = eval_target(file, node)
    for inner in descendants(node)
        kind_name(inner) == "function" || continue
        signature = children_of(inner)[1]
        while kind_name(signature) in ("where", "::")
            signature = children_of(signature)[1]
        end
        kind_name(signature) == "call" || continue
        return isnothing(target) ? call_head(signature) : "$target.$(source(file, children_of(signature)[1]))"
    end
    return nothing
end

"""Names call `node` reaches eval definition by: Base-normalized head, and callee as written (`M.f`) for prefix call."""
function call_names(file::SyntaxFile, node::SyntaxNode)::Vector{String}
    kind_name(node) == "call" || return String[]
    written = isnothing(infix_operator(node)) ? source(file, children_of(node)[1]) : nothing
    return unique!(filter(!isnothing, [call_head(node), written]))
end

"""Whether call `node` is signature of method definition, as in `f(x) = …`: definition, no call."""
function is_signature(node::SyntaxNode)::Bool
    child, parent = node, parent_of(node)
    while !isnothing(parent) && kind_name(parent) in ("where", "::") && children_of(parent)[1] === child
        child, parent = parent, parent_of(parent)
    end
    return !isnothing(parent) && kind_name(parent) == "function" && children_of(parent)[1] === child
end

"""Fix wrapping call `node` in `Base.invokelatest`; manual when call passes keywords."""
function latest_fix(file::SyntaxFile, node::SyntaxNode)::Fix
    parts = children_of(node)
    any(part -> kind_name(part) == "parameters", parts) && return manual_fix("call through `Base.invokelatest`")
    return replace_fix(file, node, "Base.invokelatest(" * join((source(file, part) for part in parts), ", ") * ")", Tier.safe)
end

"""Findings for calls in same function body after `eval` defines called function."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, definition in forms(file, "function")
        body = children_of(definition)[end]
        kind_name(body) == "block" || continue
        defined = Dict{String, Any}()
        for statement in children_of(body)
            name = evaluated_definition(file, statement)
            isnothing(name) || (defined[name] = statement; continue)
            for node in descendants(statement)
                index = findfirst(in(keys(defined)), call_names(file, node))
                (isnothing(index) || is_signature(node)) && continue
                called = call_names(file, node)[index]
                push!(
                    found, finding(
                        NAME, file, node; kind = :same_world_call, confidence = Confidence.definite,
                        message = "`$called` is called in world older than its definition",
                        label = "MethodError: method too new", why = "running function keeps world it started in; `eval` adds method to newer world",
                        fix = latest_fix(file, node), causes = [Label(span(file, defined[called]), "defined by `eval` here")],
                    )
                )
            end
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [63], Stage.syntax, findings)

end
