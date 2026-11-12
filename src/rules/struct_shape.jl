"""`wide-struct` (F78) and `field-prefix` (F79): struct shape rules on field lists."""
module StructShape

using ...Facts

"""Most fields one struct may declare before `wide-struct` reports it."""
const MAX_FIELDS = 15
"""Fewest fields sharing prefix before `field-prefix` reports them."""
const MIN_PREFIX_FIELDS = 3

"""Field name nodes of struct definition `definition`, skipping inner constructors."""
function field_names(definition)::Vector{Any}
    names = Any[]
    for field in children_of(children_of(definition)[end])
        node = kind_name(field) == "=" ? children_of(field)[1] : field
        node = kind_name(node) == "::" ? children_of(node)[1] : node
        isnothing(identifier_name(node)) || push!(names, node)
    end
    return names
end

"""Struct name text of `definition`, without parameters and supertype."""
function struct_name(file::SyntaxFile, definition)::String
    head = children_of(definition)[1]
    while kind_name(head) in ("<:", "curly")
        head = children_of(head)[1]
    end
    return source(file, head)
end

"""Findings for structs with more than `MAX_FIELDS` fields."""
function run_wide(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, definition in nodes_named(file, "struct")
        names = field_names(definition)
        length(names) > MAX_FIELDS || continue
        push!(
            found, finding(
                Symbol("wide-struct"), file, children_of(definition)[1]; kind = :many_fields, confidence = Confidence.definite,
                message = "struct `$(struct_name(file, definition))` has $(length(names)) fields",
                label = "more than $MAX_FIELDS fields", why = "wide structs mix concerns; every constructor call lists every field",
                fix = manual_fix("group related fields into nested structs"),
            )
        )
    end
    return found
end

"""Findings for groups of at least `MIN_PREFIX_FIELDS` fields sharing `prefix_` stem."""
function run_prefix(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, definition in nodes_named(file, "struct")
        groups = Dict{String, Vector{Any}}()
        for node in field_names(definition)
            name = identifier_name(node)
            occursin('_', name) || continue
            push!(get!(() -> Any[], groups, first(split(name, '_'))), node)
        end
        for (prefix, nodes) in sort!(collect(groups); by = first)
            length(nodes) >= MIN_PREFIX_FIELDS || continue
            push!(
                found, finding(
                    Symbol("field-prefix"), file, nodes[1]; kind = :shared_prefix, confidence = Confidence.definite,
                    message = "$(length(nodes)) fields of `$(struct_name(file, definition))` share prefix `$(prefix)_`",
                    label = "first `$(prefix)_` field", why = "shared prefix names hidden struct; grouping it lets code pass it as one value",
                    fix = manual_fix("move `$(prefix)_*` fields into struct, then use `$prefix.field`"),
                    causes = [Label(span(file, node), "same prefix") for node in nodes[2:end]],
                )
            )
        end
    end
    return found
end

const WIDE = RuleEntry(Symbol("wide-struct"), Group.readability, [78], Stage.syntax, run_wide)
const PREFIX = RuleEntry(Symbol("field-prefix"), Group.readability, [79], Stage.syntax, run_prefix)

end
