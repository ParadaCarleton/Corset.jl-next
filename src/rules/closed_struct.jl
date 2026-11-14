"""
`closed-struct` (F84): public struct has no abstract supertype, so users cannot add sibling types.

## Description
Reports definition of struct with supertype `Any` when public name refers to it.
Public names are names root module exports or declares `public`, and public names of submodules those names reach.

## Rationale
Methods typed on concrete struct accept only that struct. User who needs variant cannot subtype it and must copy or wrap it.
Abstract supertype gives users one type to subtype and package one type to dispatch on.

## Example
```julia
export Model
struct Model
    weights::Vector{Float64}
end
predict(model::Model, x::Vector{Float64})::Float64 = model.weights' * x
```

## Alternative
```julia
export AbstractModel, Model
abstract type AbstractModel end
struct Model <: AbstractModel
    weights::Vector{Float64}
end
predict(model::AbstractModel, x::Vector{Float64})::Float64 = model.weights' * x
```

## Limitations
Rule reads `struct` forms in package files; struct from macro without `struct` form passes.
Public alias counts: `const Pairs = Table{Pair}` makes `Table` public.
"""
module ClosedStruct

using ...Facts

const NAME = Symbol("closed-struct")

"""
Type names with supertype `Any` that public names reach: names of root module, first of package `modules`, then of
package submodules public names reach.
"""
function rootless_types(modules::Vector{Module})::Set{Core.TypeName}
    package, queue = Set(modules), [first(modules)]
    reached, rootless = Set(queue), Set{Core.TypeName}()
    while !isempty(queue)
        mod = pop!(queue)
        for name in names(mod)
            isdefined(mod, name) || continue
            binding = getglobal(mod, name)
            if binding isa Module && binding in package && !(binding in reached)
                push!(reached, binding)
                push!(queue, binding)
            end
            body = Base.unwrap_unionall(binding)
            body isa DataType && supertype(body) === Any && push!(rootless, body.name)
        end
    end
    return rootless
end

"""Findings for definitions of public package structs with supertype `Any`."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    rootless = rootless_types(package.modules)
    found = Finding[]
    for site in package.structs
        Base.unwrap_unionall(site.type).name in rootless || continue
        name = definition_name(site.node)
        push!(
            found, finding(
                NAME, site.file, name; kind = :closed_struct, confidence = Confidence.definite,
                message = "public struct `$(source(site.file, name))` has no abstract supertype", label = "users cannot add sibling type",
                why = "methods typed on concrete struct accept only it; users must copy or wrap it to vary it",
                fix = manual_fix("declare `abstract type Abstract$(source(site.file, name)) end`, subtype it, and type methods on it"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.composability, [84], Stage.package, findings)

end
