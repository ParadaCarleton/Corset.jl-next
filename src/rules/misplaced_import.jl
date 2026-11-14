"""
`misplaced-import` (F67): explicit import sits in file that uses none of its names; one other file uses them all.

## Description
Reports `using X: a`, `import X: a` and `import X` when its own file uses none of its names and exactly one other file of
its module uses them. ExplicitImports.jl finds uses. Labels mark first use of each name.
Fix moves statement, with its trailing comment, to new line above first statement of module code in that file.

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

"""Bytes of `file` line that holds `byte`: first byte, and byte before its newline."""
function line_bytes(file::SyntaxFile, byte::Int)::UnitRange{Int}
    newline = findnext(==(UInt8('\n')), codeunits(file.text), byte)
    start = something(findprev(==(UInt8('\n')), codeunits(file.text), byte - 1), 0) + 1
    return start:(isnothing(newline) ? ncodeunits(file.text) : newline - 1)
end

"""First statement of module body in `file` that holds `byte`; top-level statement when no `module` form holds it."""
function first_statement(file::SyntaxFile, byte::Int)::SyntaxNode
    holders = filter(node -> span(file, node).first_byte <= byte <= span(file, node).last_byte, forms(file, "module"))
    body = isempty(holders) ? file.tree : last(children_of(last(holders)))
    return first(children_of(body))
end

"""
Fix moving `statement` of `file` to new line above first statement of module code that holds `use` in `target`.
Statement must own its lines, and that first statement must start its line; trailing comment moves with statement.
"""
function move_fix(file::SyntaxFile, statement::Span, target::SyntaxFile, use::Span)::Fix
    first_line, last_line = line_bytes(file, statement.first_byte), line_bytes(file, statement.last_byte)
    before = file.text[first(first_line):prevind(file.text, statement.first_byte)]
    after = file.text[nextind(file.text, statement.last_byte):last(last_line)]
    anchor = span(target, first_statement(target, use.first_byte))
    line_start = first(line_bytes(target, anchor.first_byte))
    indent = target.text[line_start:prevind(target.text, anchor.first_byte)]
    destination = basename(target.path)
    # One-line `module M; …; end` has no line to insert above inside module.
    isempty(strip(before)) && (isempty(strip(after)) || startswith(lstrip(after), '#')) && isempty(strip(indent)) ||
        return manual_fix("move import to own line at top of `$destination`")
    moved = rstrip(file.text[statement.first_byte:last(last_line)])
    # Removal takes newline too, unless statement ends file.
    removed = Span(file.path, first(first_line), min(last(last_line) + 1, ncodeunits(file.text)), Precision.exact)
    inserted = Span(target.path, line_start, line_start - 1, Precision.exact)
    return Fix("move to top of `$destination`", [Edit(removed, ""), Edit(inserted, "$indent$moved\n")], Tier.safe)
end

"""Finding for `imported` when only one file other than its own uses its names; `nothing` otherwise."""
function misplaced_finding(files::Dict{String, SyntaxFile}, imported::ExplicitImport)::Union{Nothing, Finding}
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
