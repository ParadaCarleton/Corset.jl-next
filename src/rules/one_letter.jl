"""
`one-letter` (F72): one-letter name.

## Description
Reports one-letter variable, argument and loop names, once per name and function.

## Rationale
One letter carries no meaning outside its first line. Reader must find assignment to learn what value holds.

## Example
```julia
function area(w, h)
    return w * h
end
```

## Alternative
```julia
function area(width, height)
    return width * height
end
```

## Limitations
Exempt: `_`, and `i`, `j`, `k` as loop variables. Math-heavy file may opt out with `# corset: allow-file one-letter -- <reason>`.
"""
module OneLetter

using ...Facts

const NAME = Symbol("one-letter")
"""Names allowed as loop variables."""
const INDEX_NAMES = Set(["i", "j", "k"])

"""Binding kinds rule reads; definition names and fields, such as `x` of point type, stay legal."""
const VALUE_BINDINGS = (BindingKind.parameter, BindingKind.assignment, BindingKind.loop)

"""Findings for one-letter names, once per name and enclosing function."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        seen = Set{Tuple{UInt, String}}()
        for site in file.bindings
            site.kind in VALUE_BINDINGS || continue
            node, name = site.name, identifier_name(site.name)
            length(name) == 1 && name != "_" && !(site.kind == BindingKind.loop && name in INDEX_NAMES) || continue
            scope = findfirst(ancestor -> kind_name(ancestor) == "function", ancestors(node))
            # Node hash walks whole subtree; key scope by identity.
            key = (isnothing(scope) ? UInt(0) : objectid(ancestors(node)[scope]), name)
            key in seen && continue
            push!(seen, key)
            push!(
                found, finding(
                    NAME, file, node; kind = :short_name, confidence = Confidence.definite,
                    message = "one-letter name `$name`", label = "name says nothing about value",
                    why = "reader must trace value back to its source to learn what it holds",
                    fix = manual_fix("rename to what value holds"),
                )
            )
        end
    end
    return sort!(found; by = finding -> finding.primary.span.first_byte)
end

const ENTRY = RuleEntry(NAME, Group.readability, [72], Stage.syntax, run)

end
