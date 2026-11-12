"""
`field-prefix` (F79): related fields belong in nested struct, table or array.

## Description
Reports three or more fields of one struct that share prefix before `_`.

## Rationale
Shared prefix names hidden struct. Code cannot pass that group as one value, and each new member adds another field.

## Example
```julia
struct Plot
    axis_min::Float64
    axis_max::Float64
    axis_label::String
end
```

## Alternative
```julia
struct Axis
    min::Float64
    max::Float64
    label::String
end

struct Plot
    axis::Axis
end
```

## Limitations
Rule splits names at first `_` only. Minimum group size is fixed at 3 until rule options exist.
"""
module FieldPrefix

using ...Facts

const NAME = Symbol("field-prefix")
"""Fewest fields sharing prefix before rule reports them."""
const MIN_PREFIX_FIELDS = 3

"""Findings for groups of at least `MIN_PREFIX_FIELDS` fields sharing `prefix_` stem."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, definition in nodes_named(file, "struct")
        groups = Dict{String, Vector{Any}}()
        for node in struct_fields(definition)
            name = identifier_name(node)
            occursin('_', name) || continue
            push!(get!(() -> Any[], groups, first(split(name, '_'))), node)
        end
        for (prefix, nodes) in sort!(collect(groups); by = first)
            length(nodes) >= MIN_PREFIX_FIELDS || continue
            push!(
                found, finding(
                    NAME, file, nodes[1]; kind = :shared_prefix, confidence = Confidence.definite,
                    message = "$(length(nodes)) fields of `$(source(file, definition_name(definition)))` share prefix `$(prefix)_`",
                    label = "first `$(prefix)_` field", why = "shared prefix names hidden struct; grouping it lets code pass it as one value",
                    fix = manual_fix("move `$(prefix)_*` fields into struct, then use `$prefix.field`"),
                    causes = [Label(span(file, node), "same prefix") for node in nodes[2:end]],
                )
            )
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [79], Stage.syntax, run)

end
