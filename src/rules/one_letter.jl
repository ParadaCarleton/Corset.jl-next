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

"""Identifier bound by binding-site node `node` (strips `::T` and default `= value`)."""
function bound_identifier(node)
    while kind_name(node) in ("::", "=", "kw") && !isempty(children_of(node))
        node = children_of(node)[1]
    end
    return isnothing(identifier_name(node)) ? nothing : node
end

"""Binding sites in `file`: parameters, assignment targets, loop and `let` variables, each with loop flag."""
function binding_sites(file::SyntaxFile)::Vector{Tuple{Any, Bool}}
    sites = Tuple{Any, Bool}[]
    for definition in forms(file, "function")
        signature = children_of(definition)[1]
        while kind_name(signature) in ("where", "::")
            signature = children_of(signature)[1]
        end
        kind_name(signature) == "call" || continue
        for parameter in children_of(signature)[2:end]
            group = kind_name(parameter) == "parameters" ? children_of(parameter) : [parameter]
            append!(sites, ((node, false) for node in group))
        end
    end
    for assignment in forms(file, "=")
        parent = parent_of(assignment)
        kind_name(parent) in ("call", "parameters", "function") && continue
        push!(sites, (children_of(assignment)[1], kind_name(parent) in ("iteration", "for")))
    end
    for clause in forms(file, "in")
        kind_name(parent_of(clause)) == "iteration" && push!(sites, (children_of(clause)[1], true))
    end
    return sites
end

"""Findings for one-letter names, once per name and enclosing function."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        seen = Set{Tuple{UInt, String}}()
        for (site, is_loop) in binding_sites(file)
            node = bound_identifier(site)
            isnothing(node) && continue
            name = identifier_name(node)
            length(name) == 1 && name != "_" && !(is_loop && name in INDEX_NAMES) || continue
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
