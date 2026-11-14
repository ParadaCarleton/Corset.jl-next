"""Render diagnostics as Rust-style text messages."""
module Render

using ..Facts: Span, Precision, Confidence
using ..Config: Level
using ..Engine: Diagnostic, Report
using ..Rules: REGISTRY
using ..Baseline: Baseline

"""Header word for `level`, as in rustc."""
const HEADER = Dict(Level.deny => "error", Level.warn => "warning")

"""Byte offset of first byte of each line of `text`."""
line_starts(text::String)::Vector{Int} = [1; findall(==(UInt8('\n')), codeunits(text)) .+ 1]

"""Line and code-point column of byte `byte` in `text`; `byte` may sit one past end."""
function line_column(text::String, byte::Int)::Tuple{Int, Int}
    starts = line_starts(text)
    line = searchsortedlast(starts, byte)
    return line, length(text, starts[line], prevind(text, byte)) + 1
end

"""Text of line `line` without its newline."""
function line_text(text::String, starts::Vector{Int}, line::Int)::String
    stop = line < length(starts) ? starts[line + 1] - 2 : ncodeunits(text)
    return replace(chopsuffix(text[starts[line]:thisind(text, max(stop, starts[line] - 1))], "\r"), '\t' => TAB)
end

"""Display width of `text` between byte `first` and byte `stop`, inclusive."""
width_between(text::String, first::Int, stop::Int)::Int = stop < first ? 0 : textwidth(replace(text[first:thisind(text, stop)], '\t' => TAB))

"""Tab stop used for source lines; renderer expands tabs so underlines align."""
const TAB = "    "

"""1-based display column of byte `byte` on line `line`."""
column(text::String, starts::Vector{Int}, line::Int, byte::Int)::Int = width_between(text, starts[line], byte - 1) + 1

"""Line, column and underline width of `span`; multi-line span underlines to end of first line."""
function placement(text::String, starts::Vector{Int}, span::Span)::Tuple{Int, Int, Int}
    line = searchsortedlast(starts, span.first_byte)
    content = line_text(text, starts, line)
    if span.precision == Precision.line
        indent = length(content) - length(lstrip(content))
        return line, indent + 1, max(textwidth(strip(content)), 1)
    end
    line_end = starts[line] + ncodeunits(content) - 1
    first_col = column(text, starts, line, span.first_byte)
    return line, first_col, max(width_between(text, span.first_byte, min(span.last_byte, line_end)), 1)
end

"""Write source lines that `marked` entries (line, column, width, marker, label) point at, each followed by its markers."""
function write_lines(io::IO, text::String, starts::Vector{Int}, marked::Vector, gutter::String)::Nothing
    previous = 0
    for line in sort!(unique(first.(marked)))
        if previous > 0 && line - previous == 2
            println(io, lpad(line - 1, length(gutter)), " | ", line_text(text, starts, line - 1))
        elseif previous > 0 && line - previous > 2
            println(io, "...")
        end
        println(io, lpad(line, length(gutter)), " | ", line_text(text, starts, line))
        for (_, col, width, marker, label) in sort!(filter(entry -> entry[1] == line, marked); by = entry -> entry[2])
            println(io, rstrip(string(gutter, " | ", " "^(col - 1), marker^width, " ", label)))
        end
        previous = line
    end
    return nothing
end

"""
Write `diagnostic` to `io` with source text from `sources` by path; paths print relative to `root`.
Primary file comes first (`-->`); labels in other files follow, one snippet per file (`:::`), as in rustc.
`note` adds lines saying where level was set and how to opt out.
"""
function render(io::IO, diagnostic::Diagnostic, sources::Dict{String, String}, root::String, note::Bool)::Nothing
    finding = diagnostic.finding
    labels = [(finding.primary, '^'); [(cause, '-') for cause in finding.causes]]
    files = unique(label.span.file for (label, _) in labels)
    marked = Dict(
        file => [(placement(sources[file], line_starts(sources[file]), label.span)..., marker, label.text) for (label, marker) in labels if label.span.file == file]
            for file in files
    )
    gutter = " "^maximum(ndigits(first(entry)) for entries in values(marked) for entry in entries)
    println(io, HEADER[diagnostic.level], "[", finding.rule, "]: ", finding.message)
    for (index, file) in enumerate(files)
        line, col = marked[file][1][1], marked[file][1][2]
        println(io, gutter, index == 1 ? "--> " : "::: ", relpath(file, root), ":", line, ":", col)
        println(io, gutter, " |")
        write_lines(io, sources[file], line_starts(sources[file]), marked[file], gutter)
        println(io, gutter, " |")
    end
    println(io, gutter, " = why: ", finding.why)
    finding.confidence == Confidence.possible && println(io, gutter, " = confidence: possible")
    isnothing(finding.fix) || println(io, gutter, " = fix: ", finding.fix.text, "   [", finding.fix.tier, "]")
    println(io, gutter, " = docs: corset explain ", finding.rule)
    note && println(io, gutter, " = note: ", diagnostic.level, " from ", diagnostic.source)
    # Opt-outs cover registry rules only; always-on checks (opt-out, parse-error) have none.
    note && any(rule -> rule.name == finding.rule, REGISTRY) && println(io, gutter, " = note: opt out with `# corset: allow ", finding.rule, " -- <reason>`")
    return nothing
end

"""Write every diagnostic of `report`, blank line after each; level note appears once per rule."""
function render_all(io::IO, report::Report)::Nothing
    noted = Set{Symbol}()
    for diagnostic in report.diagnostics
        render(io, diagnostic, report.sources, report.root, diagnostic.finding.rule ∉ noted)
        push!(noted, diagnostic.finding.rule)
        println(io)
    end
    isempty(report.stale) || render_stale(io, report.stale)
    return nothing
end

"""Write closing line: counts of errors, warnings and baselined findings."""
function render_summary(io::IO, report::Report)::Nothing
    errors = count(diagnostic -> diagnostic.level == Level.deny, report.diagnostics) + length(report.stale)
    warnings = count(diagnostic -> diagnostic.level == Level.warn, report.diagnostics)
    println(io, "corset: ", errors, errors == 1 ? " error, " : " errors, ", warnings, warnings == 1 ? " warning, " : " warnings, ", report.baselined, " baselined")
    return nothing
end

"""Write coverage line: analyzed file count and blind spots by cause, then one line per blind spot."""
function render_coverage(io::IO, report::Report)::Nothing
    files = report.analyzed
    print(io, "coverage: analyzed ", files, files == 1 ? " file" : " files")
    if !isempty(report.blind_spots)
        causes = sort!(unique(spot.cause for spot in report.blind_spots))
        # Count follows cause, so verb phrase reads right in singular and plural.
        counts = join(("$cause: $(count(spot -> spot.cause == cause, report.blind_spots))" for cause in causes), ", ")
        print(io, "; skipped ", length(report.blind_spots), " (", counts, ")")
    end
    println(io)
    for spot in report.blind_spots
        line, column = line_column(report.sources[spot.span.file], spot.span.first_byte)
        println(io, "  - ", relpath(spot.span.file, report.root), ":", line, ":", column, ": ", spot.cause)
    end
    return nothing
end

"""Write message for baseline entries no finding matches."""
function render_stale(io::IO, stale::Vector{Baseline.Key})::Nothing
    println(io, "error[baseline]: ", length(stale), " baseline ", length(stale) == 1 ? "entry matches" : "entries match", " no finding")
    foreach(key -> println(io, "  - `", key.rule, "` in ", key.file, isempty(key.definition) ? "" : " ($(key.definition))"), stale)
    println(io, "  = why: stale entry would hide later finding with same key")
    println(io, "  = fix: run `corset baseline` to rewrite baseline")
    println(io)
    return nothing
end

end
