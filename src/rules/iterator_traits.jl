"""
`iterator-traits` (F93): iterator without element type makes `collect` build `Vector{Any}`.

## Description
Reports package struct with `Base.iterate` method when its `IteratorEltype` is `HasEltype` and no method other than Base
default covers its `eltype`. Default `IteratorEltype` is `HasEltype`. Return type inference finds trait.

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
Iterator whose `IteratorEltype` inference cannot settle to one trait passes, as trait that depends on type parameter.
"""
module IteratorTraits

using ...Facts

const NAME = Symbol("iterator-traits")

"""Type of first argument of `iterate` `method` with signature type variables; `nothing` unless it names package struct."""
function iterated(method::Method, modules::Set{Module})::Union{Nothing, Type}
    type = argument_type(method, 1)
    isnothing(type) && return nothing
    body = Base.unwrap_unionall(type)
    return body isa DataType && !isabstracttype(body) && parentmodule(body) in modules ? type : nothing
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
        "`IteratorEltype` is `HasEltype`, so `collect` trusts `eltype`; Base default `eltype` is `Any`",
        manual_fix("define `Base.eltype(::Type{<:$name})`, or `Base.IteratorEltype(::Type{<:$name}) = Base.EltypeUnknown()`"),
    )
end

"""Findings for package structs with `iterate` method whose `IteratorEltype` is `HasEltype` and `eltype` is Base default."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    modules = Set(package.modules)
    iterators = Dict{Core.TypeName, Tuple{Type, MethodSite}}()
    for site in package.methods
        tuple_parameters(site.method.sig)[1] === typeof(Base.iterate) || continue
        type = iterated(site.method, modules)
        isnothing(type) || get!(iterators, Base.unwrap_unionall(type).name, (type, site))
    end
    trusted = type -> (trait = trait_type(Base.IteratorEltype, type); trait !== Union{} && trait <: Base.HasEltype)
    return [untyped_finding(type, site) for (type, site) in values(iterators) if !own_method(Base.eltype, type) && trusted(type)]
end

const ENTRY = RuleEntry(NAME, Group.performance, [93], Stage.package, findings)

end
