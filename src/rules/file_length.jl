"""
`file-length` (F77): file too long.

## Description
Reports file longer than 1000 lines, at first line past limit.

## Rationale
Long file holds several topics. Reader cannot find code by file name, and reviews touch unrelated code.

## Example
`solver.jl` with 2400 lines: setup, iteration, output and plots.

## Alternative
Split file by topic: `setup.jl`, `iterate.jl`, `output.jl`.

## Limitations
Limit is fixed at 1000 lines until rule options exist.
"""
module FileLength

using ...Facts

const NAME = Symbol("file-length")
"""Most lines one file may have before `file-length` reports it."""
const MAX_LINES = 1000

"""Byte offset where line `line` of `text` starts; `nothing` when file is shorter."""
function line_start(text::String, line::Integer)::Union{Nothing, Int}
    offset = 1
    for _ in 2:line
        newline = findnext(==('\n'), text, offset)
        isnothing(newline) && return nothing
        offset = newline + 1
    end
    return offset <= ncodeunits(text) ? offset : nothing
end

"""Findings for files longer than `MAX_LINES` lines, placed at first line past limit."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        start = line_start(file.text, MAX_LINES + 1)
        isnothing(start) && continue
        lines = count(==('\n'), file.text) + !endswith(file.text, '\n')
        push!(
            found, Finding(
                NAME, :long_file, Confidence.definite, "file has $lines lines",
                Label(Span(file.path, start, start, Precision.line), "line $(MAX_LINES + 1): past limit of $MAX_LINES"),
                Label[], "long files mix topics; readers lose track of what lives where",
                manual_fix("split file by topic and `include` parts"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [77], Stage.syntax, findings)

end
