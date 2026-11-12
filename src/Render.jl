"""Render diagnostics as Rust-style text messages."""
module Render

using ..Facts: Span, Precision, Confidence
using ..Config: Level
using ..Engine: Diagnostic, Report
using ..OptOuts: NAME as OPT_OUT

"""Header word for `level`, as in rustc."""
const HEADER = Dict(Level.deny => "error", Level.warn => "warning")

"""Byte offset of first byte of each line of `text`."""
line_starts(text::String)::Vector{Int} = [1; findall(==(UInt8('\n')), codeunits(text)) .+ 1]

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

"""Write `diagnostic` from file with source `text` to `io`; `note` adds lines saying where level was set and how to opt out."""
function render(io::IO, diagnostic::Diagnostic, text::String, note::Bool)::Nothing
    finding = diagnostic.finding
    starts = line_starts(text)
    marked = [
        (placement(text, starts, label.span)..., marker, label.text) for (label, marker) in
            [(finding.primary, '^'); [(cause, '-') for cause in finding.causes]]
    ]
    primary_line, primary_col = marked[1][1], marked[1][2]
    lines = sort!(unique(first.(marked)))
    gutter = " "^ndigits(maximum(lines))
    println(io, HEADER[diagnostic.level], "[", finding.rule, "]: ", finding.message)
    println(io, gutter, "--> ", finding.primary.span.file, ":", primary_line, ":", primary_col)
    println(io, gutter, " |")
    previous = 0
    for line in lines
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
    println(io, gutter, " |")
    println(io, gutter, " = why: ", finding.why)
    finding.confidence == Confidence.possible && println(io, gutter, " = confidence: possible")
    isnothing(finding.fix) || println(io, gutter, " = fix: ", finding.fix.text, "   [", finding.fix.tier, "]")
    println(io, gutter, " = docs: corset explain ", finding.rule)
    note && println(io, gutter, " = note: ", diagnostic.level, " from ", diagnostic.source)
    note && finding.rule != OPT_OUT && println(io, gutter, " = note: opt out with `# corset: allow ", finding.rule, " -- <reason>`")
    return nothing
end

"""Write every diagnostic of `report`, blank line after each; level note appears once per rule."""
function render_all(io::IO, report::Report)::Nothing
    noted = Set{Symbol}()
    for diagnostic in report.diagnostics
        render(io, diagnostic, report.sources[diagnostic.finding.primary.span.file], diagnostic.finding.rule ∉ noted)
        push!(noted, diagnostic.finding.rule)
        println(io)
    end
    return nothing
end

end
