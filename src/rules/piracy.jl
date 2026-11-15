"""
`piracy` (F25): package adds method to function it does not own, and no argument type belongs to package.

## Description
Reports package method that Aqua.jl calls type piracy: other module owns function, and other modules own every argument type.
Package owns type when its modules define it; type parameter counts too, as `Vector{Box}`. Extensions own package types.
Union argument belongs to package only when package owns every member.

## Rationale
Method changes calls in every package that loads this one, so result depends on load order.
New method also invalidates compiled code of callers elsewhere, which slows load.

## Example
```julia
Base.isone(name::Symbol) = name === :one
```

## Alternative
```julia
struct Name
    symbol::Symbol
end
Base.isone(name::Name) = name.symbol === :one
```

## Limitations
`Val{:name}` and other symbol parameters count as own, as Aqua.jl treats them.
Rule sees definitions in analyzed files of loaded package only. Keyword methods report through their positional methods.
"""
module Piracy

using ...Facts

const NAME = :piracy

"""
Callee of `method` as call writes it, and function owner qualified by module: (`isone`, `Base.isone`), (`Int64`, `Core.Int64`).
Constructor on type variable names its bound as owner; union of types has no module, so it names itself.
"""
function callee_texts(method::Method)::Tuple{String, String}
    callee = tuple_parameters(method.sig)[1]
    if !Base.isType(callee)
        name = Base.isoperator(method.name) ? ":$(method.name)" : string(method.name)
        return string(method.name), "$(parentmodule(callee)).$name"
    end
    built = callee.parameters[1]
    owner = Base.unwrap_unionall(built isa TypeVar ? built.ub : built)
    return string(built isa TypeVar ? built.name : built), owner isa DataType ? "$(parentmodule(owner)).$(nameof(owner))" : string(owner)
end

"""Findings for each package method Aqua.jl calls type piracy."""
function findings(facts::FactSet)::Vector{Finding}
    external = facts.external
    isnothing(external) && return Finding[]
    return map(external.piracies) do site
        callee, owner = callee_texts(site.method)
        return Finding(
            NAME, :piracy, Confidence.definite, "`$(call_text(Symbol(callee), site.method.sig))` extends `$owner` on types package does not own",
            Label(name_span(site), "type piracy"), Label[], "method changes calls in every package that loads this one",
            manual_fix("wrap argument in own type, or move method to package that owns `$owner` or argument type"),
        )
    end
end

const ENTRY = RuleEntry(NAME, Group.composability, [25], Stage.external, findings)

end
