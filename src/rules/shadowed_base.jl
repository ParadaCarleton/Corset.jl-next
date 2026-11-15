"""
`shadowed-base` (F23): method named like Base function defines new function.

## Description
Reports function that package module creates under name of exported Base function, such as `show` or `length`.
Module gets separate function of same name, so Base function gains no method.
Finding is definite for operators and Base interface functions when each signature names package type; otherwise possible.

## Rationale
Method meant to extend Base function lands on new function. Callers outside module call `Base.show` and never reach it.
Inside module, name no longer reaches Base function: `show(stdout, 1)` throws `MethodError`. Julia 1.13 raises no error.
Packages also shadow names on purpose, such as own `parse` for file format; Corset cannot tell intent there.

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
Rule sees exported Base names only. Interface list holds functions that Julia manual interfaces ask types to extend, plus display, comparison and conversion.
Fix qualifies each method with `Base.` only when each signature names package type;
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
    arguments = tuple_parameters(method.sig)[2:end]
    return any(argument -> names_own_type(argument, modules), arguments)
end

"""Exported Base functions that Julia manual interfaces ask types to extend, plus display, comparison and conversion."""
const INTERFACE = Set(
    [
        :iterate, :eltype, :length, :size, :getindex, :setindex!, :firstindex, :lastindex, :axes, :similar, :IndexStyle, :strides, :stride,
        :propertynames, :getproperty, :setproperty!, :copy, :copyto!, :show, :isequal, :hash, :isless, :convert, :promote_rule,
    ]
)

"""Confidence of shadow `name` with method `sites`: definite for operator or interface function when each signature names package type."""
function shadow_confidence(name::Symbol, sites::Vector{MethodSite}, modules::Set{Module})::Confidence.T
    meant = (Base.isoperator(name) || name in INTERFACE) && all(site -> own_signature(site.method, modules), sites)
    return meant ? Confidence.definite : Confidence.possible
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

"""Method `sites` of function with type `created`."""
function function_sites(sites::Vector{MethodSite}, created::Type)::Vector{MethodSite}
    # Loop: closure over type value passed to `filter` compiles once per value.
    found = MethodSite[]
    for site in sites
        tuple_parameters(site.method.sig)[1] === created && push!(found, site)
    end
    return found
end

"""Findings for functions package modules create under exported Base names; one per function, at its first method."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    modules = Set(package.modules)
    found = Finding[]
    for mod in package.modules, name in names(mod; all = true)
        shadows(mod, name) || continue
        sites = function_sites(package.methods, typeof(getglobal(mod, name)))
        isempty(sites) && continue
        others = [Label(name_span(site), "another method of new function") for site in sites[2:end]]
        push!(
            found, Finding(
                NAME, :shadowed_base, shadow_confidence(name, sites, modules), "`$name` defines new function; `Base.$name` gains no method",
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
