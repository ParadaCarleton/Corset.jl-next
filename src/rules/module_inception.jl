"""
`module-inception` (F102): module named like its parent module.

## Description
Reports `module` or `baremodule` whose direct parent module has same name.

## Rationale
Inner module takes over parent's name: inside parent, `Shapes` then means inner module.
Code outside reaches inner definitions only as `Shapes.Shapes.area`, so `Shapes.area` throws.

## Example
```julia
module Shapes
module Shapes
area(r) = π * r^2
end
end
```

## Alternative
```julia
module Shapes
area(r) = π * r^2
end
```

## Limitations
Rule compares modules in one file. Module in file that parent module `include`s passes.
"""
module ModuleInception

using ...Facts

const NAME = Symbol("module-inception")

"""Name of module definition `node`; `nothing` when name is not plain identifier."""
module_name(node::SyntaxNode)::Union{Nothing, String} = identifier_name(children_of(node)[1])

"""Nearest module that encloses `node`; `nothing` at top level."""
function parent_module(node::SyntaxNode)::Union{Nothing, SyntaxNode}
    parent = parent_of(node)
    while !isnothing(parent) && kind_name(parent) != "module"
        parent = parent_of(parent)
    end
    return parent
end

"""Findings for modules whose direct parent module has same name."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, inner in forms(file, "module")
        outer, name = parent_module(inner), module_name(inner)
        !isnothing(outer) && !isnothing(name) && module_name(outer) == name || continue
        push!(
            found, finding(
                NAME, file, children_of(inner)[1]; kind = :same_name, confidence = Confidence.definite,
                message = "module `$name` is nested in module of same name", label = "inner module takes name `$name`",
                why = "outside code must write `$name.$name.x`; inside parent, `$name` no longer means parent",
                fix = manual_fix("rename inner module, or move its body into parent `$name`"),
                causes = [Label(span(file, children_of(outer)[1]), "parent module `$name`")],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [102], Stage.syntax, findings)

end
