"""
`misplaced-import` (F67): explicit import sits in file that uses none of its names; one other file uses them all.

## Description
Reports `using X: a`, `import X: a` and `import X` when its own file uses none of its names and exactly one other file of
its module uses them. ExplicitImports.jl finds uses. Labels mark first use of each name.
Fix moves statement, with its trailing comment, to new line above first statement of module code in that file.
Fix tier is `likely`: moved statement loads its package later, and code that runs between can see that.

## Rationale
Julia binds import in whole module, so placement is style. Reader of using file cannot see where name comes from.

## Example
```julia
# src/Shapes.jl
module Shapes
using LinearAlgebra: norm
include("solve.jl")  # only file that calls `norm`
end
```

## Alternative
```julia
# src/solve.jl
using LinearAlgebra: norm
```

## Limitations
Import that several files use passes: module file is its place. Statement that shares line with other code, and target
module on one line (`module M; …; end`), get manual fix. Unused import, bare `using` and `import X: a as b` pass. Module
ExplicitImports.jl cannot analyze fully passes.
"""
module MisplacedImport

using ...Facts

const NAME = Symbol("misplaced-import")

"""
Fix moving `statement` of `file` to new line above first statement of module code that holds `use` in `target`.
Statement must own its lines, and that first statement must start its line; trailing comment moves with statement.
"""
function move_fix(file::SyntaxFile, statement::Span, target::SyntaxFile, use::Span)::Fix
    destination = basename(target.path)
    lines = owned_lines(file, statement)
    inserted = isnothing(lines) ? nothing : module_top_insertion(target, use.first_byte, rstrip(file.text[statement.first_byte:last(lines)]))
    isnothing(inserted) && return manual_fix("move import to own line at top of `$destination`")
    return Fix("move to top of `$destination`", [line_deletion(file, something(lines)), inserted], Tier.likely)
end

"""Finding for `imported` when only one file other than its own uses its names; `nothing` otherwise."""
function misplaced_finding(files::AbstractDict{String, SyntaxFile}, imported::ExplicitImport)::Union{Nothing, Finding}
    users = unique(use.file for (_, use) in imported.uses)
    length(users) == 1 && only(users) != imported.statement.file || return nothing
    target = files[only(users)]
    firsts = [(name, first(use for (used, use) in imported.uses if used == name)) for name in unique(first.(imported.uses))]
    return Finding(
        NAME, :misplaced_import, Confidence.definite, "import is used only in `$(basename(target.path))`",
        Label(imported.statement, "this file uses none of its names"), [Label(use, "uses `$name`") for (name, use) in firsts],
        "reader of using file cannot see where names come from", move_fix(files[imported.statement.file], imported.statement, target, last(first(firsts))),
    )
end

"""Findings for each explicit import whose names only one other file of its module uses."""
function findings(facts::FactSet)::Vector{Finding}
    external = facts.external
    isnothing(external) && return Finding[]
    files = Dict(file.path => file for file in facts.files)
    return Finding[found for found in (misplaced_finding(files, imported) for imported in external.explicit_imports) if !isnothing(found)]
end

const ENTRY = RuleEntry(NAME, Group.readability, [67], Stage.external, findings)

end
