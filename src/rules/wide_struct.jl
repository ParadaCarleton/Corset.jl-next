"""
`wide-struct` (F78): struct with too many fields.

## Description
Reports struct with more than 15 fields.

## Rationale
Wide struct usually mixes several concerns. Every constructor call lists every field, so callers break on each change.

## Example
```julia
struct Simulation
    grid_size::Int
    grid_spacing::Float64
    # … 14 more fields
end
```

## Alternative
```julia
struct Simulation
    grid::Grid
    solver::Solver
    output::Output
end
```

## Limitations
Limit is fixed at 15 fields until rule options exist.
"""
module WideStruct

using ...Facts

const NAME = Symbol("wide-struct")
"""Most fields one struct may declare before rule reports it."""
const MAX_FIELDS = 15

"""Findings for structs with more than `MAX_FIELDS` fields."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, definition in forms(file, "struct")
        fields = struct_fields(definition)
        length(fields) > MAX_FIELDS || continue
        push!(
            found, finding(
                NAME, file, children_of(definition)[1]; kind = :many_fields, confidence = Confidence.definite,
                message = "struct `$(source(file, definition_name(definition)))` has $(length(fields)) fields",
                label = "more than $MAX_FIELDS fields", why = "wide structs mix concerns; every constructor call lists every field",
                fix = manual_fix("group related fields into nested structs"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [78], Stage.syntax, findings)

end
