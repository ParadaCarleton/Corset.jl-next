"""
`unused-import` (F105): explicit import binds name its module never uses.

## Description
Reports names of `using X: a`, `import X: a` and `import X` that module never uses; ExplicitImports.jl finds uses.
Use: call, method extension, `export`, `public`, `@eval` interpolation. One finding per statement.
Fix removes unused names, or whole statement when none is used.
Import that binds package it loads (`import X`, `using X: X`) gets manual fix: loading runs `__init__` and extension triggers.
Removal of whole statement gets manual fix too when no other import loads its package. Package code and scripts count apart.

## Rationale
Reader looks for use that does not exist. Import of name package dropped keeps stale dependency alive.

## Example
```julia
using LinearAlgebra: norm, dot
area(sides) = norm(sides)
```

## Alternative
```julia
using LinearAlgebra: norm
area(sides) = norm(sides)
```

## Limitations
Bare `using`, `import X: a as b` and module ExplicitImports.jl cannot analyze fully pass; `implicit-import` reports
bare `using` that brings no used name. Removed import can break code outside package that reaches name through it.
"""
module UnusedImport

using ...Facts

const NAME = Symbol("unused-import")

"""`:` node of `using X: a` or `import X: a`, always only child; `nothing` for `import A, B.C`."""
function colon_of(statement::SyntaxNode)::Union{Nothing, SyntaxNode}
    head = first(children_of(statement))
    return kind_name(head) == ":" ? head : nothing
end

"""Module path nodes of `statement` that each bind name: those after `:` in `using X: a`, else every path."""
function bound_paths(statement::SyntaxNode)::Vector{SyntaxNode}
    colon = colon_of(statement)
    return collect(isnothing(colon) ? children_of(statement) : children_of(colon)[2:end])
end

"""Name module path node `path` binds, `@` included for macro."""
function bound_name(file::SyntaxFile, path::SyntaxNode)::Symbol
    leaf = last(children_of(path))
    return Symbol(kind_name(leaf) == "MacroName" ? "@" : "", source(file, leaf))
end

"""
Whether `path` of `statement` binds package module statement loads: `import X`, `import X as Y`, `using X: X`.
Such import may exist only to load package, as `import MKL` switches BLAS backend.
"""
function binds_package(file::SyntaxFile, statement::SyntaxNode, path::SyntaxNode)::Bool
    colon = colon_of(statement)
    loaded = isnothing(colon) ? path : first(children_of(colon))
    kind_name(loaded) == "as" && (loaded = first(children_of(loaded)))
    pieces = children_of(loaded)
    (length(pieces) == 1 && kind_name(pieces[1]) != ".") || return false
    return isnothing(colon) || source(file, path) == source(file, loaded)
end

"""Packages `statement` of `file` loads, by first name of module path: `X` for `using X.Inner: a`; relative path loads none."""
function loaded_packages(file::SyntaxFile, statement::SyntaxNode)::Vector{String}
    colon = colon_of(statement)
    paths, found = isnothing(colon) ? children_of(statement) : children_of(colon)[1:1], String[]
    for path in paths
        head = first(children_of(kind_name(path) == "as" ? first(children_of(path)) : path))
        kind_name(head) == "." || push!(found, source(file, head))
    end
    return unique!(found)
end

"""Manual fix that removes import, unless loading `packages` has intended effect."""
load_fix(packages::AbstractVector{String})::Fix = manual_fix("remove import, unless loading $(join(("`$name`" for name in packages), ", ")) has intended effect")

"""
Fix removing `unused` paths of `statement`: rewrite with kept paths, or delete lines of statement with none kept.
Manual when unused path binds package, or when deleted statement is only import of file role that loads package in
`sole`: load effects may be intended.
"""
function removal_fix(file::SyntaxFile, statement::SyntaxNode, unused::AbstractVector{SyntaxNode}, sole::AbstractSet{Tuple{Role.T, String}})::Fix
    loads = [source(file, path) for path in unused if binds_package(file, statement, path)]
    isempty(loads) || return load_fix(loads)
    kept = [path for path in bound_paths(statement) if !any(node -> node === path, unused)]
    if isempty(kept)
        dropped = filter(package -> (file.role, package) in sole, loaded_packages(file, statement))
        isempty(dropped) || return load_fix(dropped)
        lines = owned_lines(file, span(file, statement))
        isnothing(lines) && return manual_fix("remove import")
        return Fix("remove import", [line_deletion(file, lines)], Tier.likely)
    end
    colon = colon_of(statement)
    head = isnothing(colon) ? "" : "$(source(file, first(children_of(colon)))): "
    return replace_fix(file, statement, "$(kind_name(statement)) $head$(join((source(file, path) for path in kept), ", "))", Tier.likely)
end

"""
Finding for `imported` statement of `file` with names its module never uses; `nothing` when all are used. `sole` holds
packages only one import of file role loads.
"""
function unused_finding(file::SyntaxFile, imported::ExplicitImport, sole::AbstractSet{Tuple{Role.T, String}})::Union{Nothing, Finding}
    statement = only(node for kind in ("using", "import") for node in forms(file, kind) if span(file, node) == imported.statement)
    used = Set(first.(imported.uses))
    # ExplicitImports.jl gives `var"name"` path no import row; such name is no known name.
    unused = [path for path in bound_paths(statement) if bound_name(file, path) in imported.names && bound_name(file, path) ∉ used]
    isempty(unused) && return nothing
    names = join(("`$(bound_name(file, path))`" for path in unused), ", ")
    labels = [Label(span(file, path), "never used") for path in unused]
    return Finding(
        NAME, :unused_import, Confidence.definite, "unused $(length(unused) == 1 ? "import" : "imports"): $names", first(labels),
        labels[2:end], "reader looks for use that does not exist", removal_fix(file, statement, unused, sole),
    )
end

"""Findings for each explicit import statement with names its module never uses."""
function findings(facts::FactSet)::Vector{Finding}
    external = facts.external
    isnothing(external) && return Finding[]
    files = Dict(file.path => file for file in facts.files)
    counts = Dict{Tuple{Role.T, String}, Int}()
    for file in facts.files, kind in ("using", "import"), statement in forms(file, kind), package in loaded_packages(file, statement)
        counts[(file.role, package)] = get(counts, (file.role, package), 0) + 1
    end
    # Julia loads `Base` and `Core` before any package.
    sole = Set(key for (key, count) in counts if count == 1 && !(last(key) in ("Base", "Core")))
    found = (unused_finding(files[imported.statement.file], imported, sole) for imported in external.explicit_imports)
    return Finding[finding for finding in found if !isnothing(finding)]
end

const ENTRY = RuleEntry(NAME, Group.readability, [105], Stage.external, findings)

end
