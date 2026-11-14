"""
`operator-consistency` (F22, F104): `==` defined without `hash`; method on derived operator.

## Description
Reports `==` or `isequal` method for package type that `hash` does not cover beyond Base default.
Also reports method on `!=`, `>` or `>=`, operators Base derives from `==`, `<` and `<=`.

## Rationale
`Dict` and `Set` find keys by `hash`, then `isequal`, and `isequal` falls back to `==`.
Base default `hash` hashes object identity, so two equal values land in separate slots.
Own method on derived operator can drift from operator it derives from: `a != b` and `!(a == b)` then differ.

## Example
```julia
struct Tags
    names::Vector{String}
end
Base.:(==)(a::Tags, b::Tags) = a.names == b.names
Base.:(!=)(a::Tags, b::Tags) = a.names != b.names
```

## Alternative
```julia
struct Tags
    names::Vector{String}
end
Base.:(==)(a::Tags, b::Tags) = a.names == b.names
Base.hash(tags::Tags, h::UInt) = hash(tags.names, hash(Tags, h))
```

## Limitations
Rule checks that some `hash` method covers compared type, not that it hashes fields `==` compares.
Equality method counts when its first package type argument is struct or abstract type; unions are skipped.
"""
module OperatorConsistency

using ...Facts

const NAME = Symbol("operator-consistency")

"""Operators Base derives from other operator: derived operator, its source, and Base definition."""
const DERIVED = [(operator = !=, source = "==", definition = "!(a == b)"), (operator = >, source = "<", definition = "b < a"), (operator = >=, source = "<=", definition = "b <= a")]

"""Function type of `method`: `typeof(==)` for method of `==`."""
function_type(method::Method)::Any = Base.unwrap_unionall(method.sig).parameters[1]

"""First argument type of equality `method` that names type package `modules` define, with signature type variables; else `nothing`."""
function compared_type(method::Method, modules::Set{Module})::Union{Nothing, Type}
    for argument in Base.unwrap_unionall(method.sig).parameters[2:end]
        bound = argument isa TypeVar ? argument.ub : argument
        body = Base.unwrap_unionall(bound)
        body isa DataType && parentmodule(body) in modules && return Base.rewrap_unionall(bound, method.sig)
    end
    return nothing
end

"""Whether `hash` method other than Base `fallback` covers every value of `type`."""
own_hash(type::Type, fallback::Method)::Bool =
    any(method -> method !== fallback && Tuple{typeof(Base.hash), type, UInt} <: method.sig, methods(Base.hash, Tuple{type, UInt}))

"""Finding for method `site` on derived operator `derived`."""
function derived_finding(site::MethodSite, derived::NamedTuple)::Finding
    operator = nameof(derived.operator)
    return Finding(
        NAME, :derived_operator, Confidence.definite, "method on `$operator`, which Base derives from `$(derived.source)`",
        Label(name_span(site), "can disagree with `$(derived.source)`"), Label[],
        "Base defines `a $operator b` as `$(derived.definition)`; own method can drift from it",
        manual_fix("delete method; define `$(derived.source)` only"),
    )
end

"""Finding for equality method `sites` on package type `type` that `hash` does not cover; primary at first site."""
function unhashed_finding(type::Type, sites::Vector{MethodSite})::Finding
    name = nameof(Base.unwrap_unionall(type))
    return Finding(
        NAME, :eq_without_hash, Confidence.definite, "`$(first(sites).method.name)` defined for `$name` without `hash`",
        Label(name_span(first(sites)), "equality without matching `hash`"), [Label(name_span(site), "also defines equality") for site in sites[2:end]],
        "`Dict` and `Set` find keys by `hash`; Base default hashes identity, so equal values miss",
        manual_fix("define `Base.hash(x::$name, h::UInt)` from fields equality compares"),
    )
end

"""Findings for package methods on derived operators, and for package types with equality but Base default `hash`."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    modules = Set(package.modules)
    fallback = which(Base.hash, Tuple{Any, UInt})
    found = Finding[]
    unhashed = Dict{Core.TypeName, Tuple{Type, Vector{MethodSite}}}()
    for site in package.methods
        type = function_type(site.method)
        derived = findfirst(entry -> type === typeof(entry.operator), DERIVED)
        isnothing(derived) || push!(found, derived_finding(site, DERIVED[derived]))
        type in (typeof(==), typeof(isequal)) || continue
        compared = compared_type(site.method, modules)
        (isnothing(compared) || own_hash(compared, fallback)) && continue
        push!(last(get!(unhashed, Base.unwrap_unionall(compared).name, (compared, MethodSite[]))), site)
    end
    return [found; [unhashed_finding(type, sites) for (type, sites) in values(unhashed)]]
end

const ENTRY = RuleEntry(NAME, Group.correctness, [22, 104], Stage.package, findings)

end
