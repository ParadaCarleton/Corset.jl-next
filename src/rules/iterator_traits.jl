"""
`iterator-traits` (F93): iterator without element type makes `collect` build `Vector{Any}`.

## Description
Reports package struct with `Base.iterate` method when no method other than Base default covers its `eltype` or `IteratorEltype`.

## Rationale
Default `IteratorEltype` is `HasEltype`, so `collect` and `Set` trust `eltype`. Base default `eltype` is `Any`.
`collect` then builds `Vector{Any}`, and code that reads it is slow.
`Base.EltypeUnknown()` makes `collect` find element type from values.

## Example
```julia
struct Countdown
    start::Int
end
Base.iterate(countdown::Countdown, count::Int = countdown.start)::Union{Nothing, Tuple{Int, Int}} =
    count < 1 ? nothing : (count, count - 1)
Base.length(countdown::Countdown)::Int = countdown.start
```

## Alternative
```julia
Base.eltype(::Type{Countdown})::Type = Int
```

## Limitations
Abstract types and unions as `iterate` argument pass; each subtype can define `eltype`.
`eltype` method that covers only some parameters, as `eltype(::Type{Cycle{Int}})`, reports.
"""
module IteratorTraits

using ...Facts

const NAME = Symbol("iterator-traits")

"""Type of first argument of `iterate` `method` with signature type variables; `nothing` unless it names package struct."""
function iterated(method::Method, modules::Set{Module})::Union{Nothing, Type}
    parameters = Base.unwrap_unionall(method.sig).parameters
    length(parameters) < 2 && return nothing
    bound = parameters[2] isa TypeVar ? parameters[2].ub : parameters[2]
    body = Base.unwrap_unionall(bound)
    body isa DataType && !isabstracttype(body) && parentmodule(body) in modules || return nothing
    return Base.rewrap_unionall(bound, method.sig)
end

"""Whether method of `trait` other than Base defaults covers every value `x` of `type`, as `trait(typeof(x))` or `trait(x)`."""
function own_method(trait::Union{Function, Type}, type::Type)::Bool
    defaults = (which(trait, Tuple{Type}), which(trait, Tuple{Any}))
    body, head = Base.unwrap_unionall(type), Core.Typeof(trait)
    calls = (Base.rewrap_unionall(Tuple{head, Type{body}}, type), Base.rewrap_unionall(Tuple{head, body}, type))
    return any(method -> !(method in defaults) && any(call -> call <: method.sig, calls), methods(trait))
end

"""Finding for iterator `type` whose first `iterate` method is at `site`."""
function untyped_finding(type::Type, site::MethodSite)::Finding
    name = nameof(Base.unwrap_unionall(type))
    return Finding(
        NAME, :untyped_iterator, Confidence.definite, "`iterate` on `$name` without `eltype`; `collect` builds `Vector{Any}`",
        Label(name_span(site), "element type defaults to `Any`"), Label[],
        "default `IteratorEltype` trusts `eltype`, and Base default `eltype` is `Any`",
        manual_fix("define `Base.eltype(::Type{<:$name})`, or `Base.IteratorEltype(::Type{<:$name}) = Base.EltypeUnknown()`"),
    )
end

"""Findings for package structs with `iterate` method whose `eltype` and `IteratorEltype` are Base defaults."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    modules = Set(package.modules)
    iterators = Dict{Core.TypeName, Tuple{Type, MethodSite}}()
    for site in package.methods
        Base.unwrap_unionall(site.method.sig).parameters[1] === typeof(Base.iterate) || continue
        type = iterated(site.method, modules)
        isnothing(type) || get!(iterators, Base.unwrap_unionall(type).name, (type, site))
    end
    return [untyped_finding(type, site) for (type, site) in values(iterators) if !own_method(Base.eltype, type) && !own_method(Base.IteratorEltype, type)]
end

const ENTRY = RuleEntry(NAME, Group.performance, [93], Stage.package, findings)

end
