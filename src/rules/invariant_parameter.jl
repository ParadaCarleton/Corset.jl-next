"""
`invariant-parameter` (F14): argument type with abstract type parameter rejects containers of its subtypes.

## Description
Reports abstract type, other than `Any`, as parameter of parametric type in argument annotation: `Vector{Real}`.

## Rationale
Type parameters are invariant: `Vector{Float64}` is not subtype of `Vector{Real}`.
Method with `values::Vector{Real}` accepts only vectors created with element type `Real`; `[1.0, 2.0]` raises `MethodError`.
`Tuple` is covariant and passes.

## Example
```julia
total(values::Vector{Real})::Real = sum(values)
```

## Alternative
```julia
total(values::Vector{<:Real})::Real = sum(values)
```

## Limitations
Rule reads parameters written as names at outer level of annotation; `Dict{String, Vector{Real}}` and type aliases pass.
`where` bounds pass. `Any` passes, since `Vector{Any}` often holds mixed values on purpose.
"""
module InvariantParameter

using ...Facts

const NAME = Symbol("invariant-parameter")

"""Names of type variables `where` clauses of signature `sig` bind."""
function type_variables(sig::Type)::Set{Symbol}
    names = Set{Symbol}()
    while sig isa UnionAll
        push!(names, sig.var.name)
        sig = sig.body
    end
    return names
end

"""Whether parametric type `head` matches its parameters exactly: not `Tuple`, `Type` or `Val`."""
function invariant(head::Type)::Bool
    head isa UnionAll && head !== Type && head !== Val || return false
    body = Base.unwrap_unionall(head)
    return body isa DataType && !(body <: Tuple)
end

"""Whether `parameter` is abstract type other than `Any` and `Union{}`, so invariant parameter rejects its subtypes."""
abstract_parameter(parameter::Type)::Bool = parameter !== Any && parameter !== Union{} && !isconcretetype(parameter)

"""Findings for abstract parameters of invariant types in argument annotations of `site`, keyed on parameter node in `seen`."""
function site_findings(site::MethodSite, seen::Base.IdSet{SyntaxNode})::Vector{Finding}
    parts = isnothing(site.node) ? nothing : signature(site.node)
    isnothing(parts) && return Finding[]
    call = first(parts)
    file, mod, bound = site.file, site.method.module, type_variables(site.method.sig)
    found = Finding[]
    for argument in children_of(call)[2:end], annotation in argument_annotations(argument)
        kind_name(annotation) == "curly" || continue
        head = resolve_type(mod, file, children_of(annotation)[1])
        (isnothing(head) || !invariant(head)) && continue
        for parameter in children_of(annotation)[2:end]
            parameter in seen && continue
            kind_name(parameter) == "Identifier" && Symbol(identifier_name(parameter)) in bound && continue
            resolved = resolve_type(mod, file, parameter)
            (isnothing(resolved) || !abstract_parameter(resolved)) && continue
            push!(seen, parameter)
            name = source(file, parameter)
            push!(
                found, finding(
                    NAME, file, parameter; kind = :invariant_parameter, confidence = Confidence.definite,
                    message = "`$(source(file, annotation))` matches parameter `$name` exactly; subtypes of `$name` miss",
                    label = "invariant parameter", why = "type parameters are invariant: `Vector{Float64}` is not `Vector{Real}`",
                    fix = replace_fix(file, parameter, "<:$name", Tier.likely),
                )
            )
        end
    end
    return found
end

"""Findings for argument annotations of package methods with abstract parameter of invariant type."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    # Default arguments give one definition several methods; each parameter node reports once.
    seen = Base.IdSet{SyntaxNode}()
    return reduce(vcat, (site_findings(site, seen) for site in package.methods); init = Finding[])
end

const ENTRY = RuleEntry(NAME, Group.correctness, [14], Stage.package, findings)

end
