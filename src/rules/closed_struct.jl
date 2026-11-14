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

"""Type name of struct that constructor `method` builds; `nothing` for other method."""
function constructed(method::Method)::Union{Nothing, Core.TypeName}
    callee = Base.unwrap_unionall(Base.unwrap_unionall(method.sig).parameters[1])
    Base.isType(callee) || return nothing
    target = Base.unwrap_unionall(callee.parameters[1])
    return target isa DataType ? target.name : nothing
end

"""Byte where line holding byte `index` of `text` starts."""
line_start(text::String, index::Int)::Int = something(findprev(==(UInt8('\n')), codeunits(text), index), 0) + 1

"""Findings for definitions of public package structs with supertype `Any`."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    rootless = rootless_types(package.modules)
    # Default and inner constructors start on lines of struct definition; sites of package methods tie it to its type.
    sites = filter(site -> constructed(site.method) in rootless, package.methods)
    found = Finding[]
    for file in facts.files, definition in forms(file, "struct")
        name, bytes = definition_name(definition), span(file, definition)
        lines, type = line_start(file.text, bytes.first_byte):bytes.last_byte, Symbol(source(file, name))
        any(site -> site.file.path == file.path && site.span.first_byte in lines && constructed(site.method).name === type, sites) || continue
        push!(
            found, finding(
                NAME, file, name; kind = :closed_struct, confidence = Confidence.definite,
                message = "public struct `$(source(file, name))` has no abstract supertype", label = "users cannot add sibling type",
                why = "methods typed on concrete struct accept only it; users must copy or wrap it to vary it",
                fix = manual_fix("declare `abstract type Abstract$(source(file, name)) end`, subtype it, and type methods on it"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.composability, [84], Stage.package, findings)

end
