"""
`shadowed-base` (F23): method named like Base function defines new function.

## Description
Reports function that package module creates under name of exported Base function, such as `show` or `length`.
Module gets separate function of same name, so Base function gains no method.

## Rationale
Method meant to extend Base function lands on new function. Callers outside module call `Base.show` and never reach it.
Inside module, name no longer reaches Base function: `show(stdout, 1)` throws `MethodError`. Julia 1.13 raises no error.

## Example
```julia
struct Square
    side::Float64
end
show(io::IO, square::Square) = print(io, "Square(", square.side, ")")
```

## Alternative
```julia
struct Square
    side::Float64
end
Base.show(io::IO, square::Square) = print(io, "Square(", square.side, ")")
```

## Limitations
Rule sees exported Base names only. Fix qualifies each method with `Base.` only when each signature names package type;
otherwise method on Base function would be type piracy, and fix is manual.
"""
module ShadowedBase

using ...Facts

const NAME = Symbol("shadowed-base")

"""Whether binding `name` of `mod` holds function `mod` created under name of exported Base function."""
function shadows(mod::Module, name::Symbol)::Bool
    Base.isexported(Base, name) && isdefined(Base, name) && isdefined(mod, name) || return false
    Base.binding_module(mod, name) === mod || return false
    created, base = getglobal(mod, name), getglobal(Base, name)
    return created isa Function && base isa Function && created !== base && parentmodule(created) === mod
end

"""Whether `type` names type of package `modules`, in parameters, unions and `where` bodies included."""
function names_own_type(type::Any, modules::Set{Module})::Bool
    type isa UnionAll && return names_own_type(Base.unwrap_unionall(type), modules)
    type isa Union && return names_own_type(type.a, modules) || names_own_type(type.b, modules)
    type isa DataType || return false
    return parentmodule(type) in modules || any(parameter -> names_own_type(parameter, modules), type.parameters)
end

"""Whether `method` signature names package type in argument other than function itself."""
function own_signature(method::Method, modules::Set{Module})::Bool
    arguments = Base.unwrap_unionall(method.sig).parameters[2:end]
    return any(argument -> names_own_type(argument, modules), arguments)
end

"""Qualified name of Base function `name` as definition writes it: `Base.show`, `Base.:+`."""
qualified(name::Symbol)::String = Base.isoperator(name) ? "Base.:$name" : "Base.$name"

"""Fix for shadow with method `sites`: qualify each definition name, or manual when site lacks node or signature names no package type."""
function shadow_fix(name::Symbol, sites::Vector{MethodSite}, modules::Set{Module})::Fix
    exact = all(site -> !isnothing(site.node), sites)
    exact && all(site -> own_signature(site.method, modules), sites) || return manual_fix("rename function, or extend `$(qualified(name))` for package types only")
    edits = [Edit(span(site.file, definition_name(site.node)), qualified(name)) for site in sites]
    return Fix("extend `$(qualified(name))`", edits, Tier.likely)
end

"""Span of definition name at `site`; whole line when site has no definition node."""
name_span(site::MethodSite)::Span = isnothing(site.node) ? site.span : span(site.file, definition_name(site.node))

"""Findings for functions package modules create under exported Base names; one per function, at its first method."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    modules = Set(package.modules)
    found = Finding[]
    for mod in package.modules, name in names(mod; all = true)
        shadows(mod, name) || continue
        created = typeof(getglobal(mod, name))
        sites = filter(site -> Base.unwrap_unionall(site.method.sig).parameters[1] === created, package.methods)
        isempty(sites) && continue
        others = [Label(name_span(site), "another method of new function") for site in sites[2:end]]
        push!(
            found, Finding(
                NAME, :shadowed_base, Confidence.definite, "`$name` defines new function; `Base.$name` gains no method",
                Label(name_span(sites[1]), "creates `$(nameof(mod)).$name`"), others,
                "callers of `Base.$name` never reach these methods, and `$name` inside module no longer reaches Base",
                shadow_fix(name, sites, modules),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [23], Stage.package, findings)

end
