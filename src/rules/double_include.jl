"""
`double-include` (F64): same file included twice.

## Description
Reports second and later `include` of same file in one run, and `include` of entry file Julia already loads (module file, extension, test entry).
Paths resolve as discovery resolves them: string literal, `raw` string, `@__DIR__`, and `joinpath` of those.

## Rationale
Each `include` evaluates file again. Struct definitions then throw on redefinition, and methods are defined twice.
Including entry file loads it twice, or recurses until stack overflows.

## Example
```julia
include("utils.jl")
include("solver.jl")   # solver.jl also includes "utils.jl"
```

## Alternative
Include each file once, from module root file.

## Limitations
Computed paths pass.
"""
module DoubleInclude

using ...Facts

const NAME = Symbol("double-include")

"""Label at first code of entry file `file`; `nothing` for file without code."""
function entry_label(file::SyntaxFile)::Union{Nothing, Label}
    statements = children_of(file.tree)
    return isempty(statements) ? nothing : Label(span(file, statements[1]), "Julia loads entry file directly")
end

"""Findings for second and later `include` of same file across run; entry files count as loaded once."""
function findings(facts::FactSet)::Vector{Finding}
    first_seen = Dict{String, Label}()
    for file in facts.files
        label = file.path in facts.entries ? entry_label(file) : nothing
        isnothing(label) || (first_seen[file.path] = label)
    end
    found = Finding[]
    for file in facts.files, call in include_calls(file)
        path = include_target(file, call)
        isnothing(path) && continue
        if !haskey(first_seen, path)
            first_seen[path] = Label(span(file, call), "first included here")
            continue
        end
        push!(
            found, finding(
                NAME, file, call; kind = :repeated_include, confidence = Confidence.definite,
                message = "`$(source(file, call))` includes file again", label = "second copy of every definition",
                why = "methods are redefined and structs error or shadow; load order then decides behavior",
                fix = manual_fix("include each file once, from package entry file"), causes = [first_seen[path]],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [64], Stage.syntax, findings)

end
