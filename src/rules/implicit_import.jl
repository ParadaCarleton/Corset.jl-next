"""
`implicit-import` (F65): bare `using X` brings names module uses without naming them.

## Description
Reports bare `using X` when module uses names `X` exports; ExplicitImports.jl finds them. Labels mark first use of each name.
Fix writes `using X: X, name, …`; it keeps `X`, since bare `using` binds module name too.
Names of `Base`, `Core` and own package pass.

## Rationale
Reader cannot tell where name comes from. Name exporter adds later can clash with own name or other `using`.

## Example
```julia
using LinearAlgebra
area(sides) = norm(sides)
```

## Alternative
```julia
using LinearAlgebra: LinearAlgebra, norm
area(sides) = norm(sides)
```

## Limitations
`using` with several modules, as `using A, B`, gets manual fix. Module ExplicitImports.jl cannot analyze fully (dynamic
`include`, module macro writes) passes.
"""
module ImplicitImport

using ...Facts

const NAME = Symbol("implicit-import")

"""`using` statement of `file` that holds `target`, and its module path node that holds it."""
function statement_path(file::SyntaxFile, target::Span)::Tuple{SyntaxNode, SyntaxNode}
    holds(node::SyntaxNode) = span(file, node).first_byte <= target.first_byte <= span(file, node).last_byte
    statement = only(filter(holds, forms(file, "using")))
    return statement, only(filter(holds, children_of(statement)))
end

"""Finding for bare `using` that brings `imported` names, with fix that names them."""
function implicit_finding(file::SyntaxFile, imported::BareUsing)::Finding
    statement, path = statement_path(file, imported.statement)
    module_path = source(file, path)
    replacement = "using $module_path: $(join([nameof(imported.exporter); imported.names], ", "))"
    single = length(children_of(statement)) == 1
    fix = single ? replace_fix(file, statement, replacement, Tier.likely) : manual_fix("move `$module_path` to own statement: `$replacement`")
    used = length(imported.names)
    message = used == 0 ? "bare `using $module_path` brings no used name" : "bare `using $module_path` brings $used used $(used == 1 ? "name" : "names") implicitly"
    return Finding(
        NAME, :implicit_import, Confidence.definite, message, Label(span(file, path), "brings every name `$module_path` exports"),
        [Label(use, "uses `$name`") for (name, use) in imported.uses], "reader cannot tell where name comes from, and new export can clash", fix,
    )
end

"""Findings for each bare `using` in analyzed files of loaded package."""
function findings(facts::FactSet)::Vector{Finding}
    external = facts.external
    isnothing(external) && return Finding[]
    files = Dict(file.path => file for file in facts.files)
    return [implicit_finding(files[imported.statement.file], imported) for imported in external.bare_usings]
end

const ENTRY = RuleEntry(NAME, Group.composability, [65], Stage.external, findings)

end
