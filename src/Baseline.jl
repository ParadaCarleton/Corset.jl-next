"""
Baseline: known findings that never fail run, stored in `corset-baseline.toml` at project root.

Key has no line numbers: rule, file, enclosing definition and hash of whitespace-normalized snippet.
Edits elsewhere keep matches. Entry that matches no finding is stale and fails run until `corset baseline` rewrites file.
"""
module Baseline

using IntervalTrees: IntervalTree, IntervalValue
using SHA: sha1
using TOML: TOML
using ..Facts: Facts, SyntaxFile, FactSet, Finding, SyntaxNode
using ..Config: ConfigError

"""Baseline file name at project root."""
const FILE = "corset-baseline.toml"

"""Kinds that open named definition."""
const DEFINITIONS = Set(["function", "macro", "struct", "module", "abstract", "primitive"])

"""Identity of finding that survives edits elsewhere in file."""
struct Key
    rule::String
    file::String
    definition::String
    snippet::String
end

"""Fields every `[[finding]]` table holds."""
const FIELDS = Set(["rule", "file", "definition", "snippet", "count"])

"""Key and count of one `[[finding]]` table; wrong field set or field type throws."""
function entry(table::AbstractDict{String, Any})::Pair{Key, Int}
    Set(keys(table)) == FIELDS || throw(ArgumentError("entry needs exactly fields $(join(sort!(collect(FIELDS)), ", "))"))
    return Key(table["rule"]::String, table["file"]::String, table["definition"]::String, table["snippet"]::String) => table["count"]::Int
end

"""Named definitions of `file` in interval tree over their bytes: lookup cost stays logarithmic in file size."""
struct Definitions
    file::SyntaxFile
    tree::IntervalTree{Int, IntervalValue{Int, SyntaxNode}}
end

function Definitions(file::SyntaxFile)::Definitions
    intervals = [IntervalValue(extrema(Facts.trimmed_bytes(file.text, node))..., node) for kind in DEFINITIONS for node in Facts.forms(file, kind)]
    return Definitions(file, IntervalTree{Int, IntervalValue{Int, SyntaxNode}}(sort!(intervals)))
end

"""Name of innermost definition enclosing byte `byte`; empty string at top level."""
function definition_name(definitions::Definitions, byte::Integer)::String
    enclosing = collect(intersect(definitions.tree, (byte, byte)))
    isempty(enclosing) && return ""
    return Facts.source(definitions.file, Facts.definition_name(argmin(interval -> last(interval) - first(interval), enclosing).value))
end

"""Key of `finding` in file of `definitions`, with path relative to `root`."""
function key(definitions::Definitions, root::String, finding::Finding)::Key
    span, file = finding.primary.span, definitions.file
    snippet = join(split(String(codeunits(file.text)[(span.first_byte):(span.last_byte)])), " ")
    return Key(string(finding.rule), relpath(file.path, root), definition_name(definitions, span.first_byte), bytes2hex(sha1(snippet))[1:16])
end

"""Key of each of `findings` in `facts`, with paths relative to `root`."""
function finding_keys(facts::FactSet, root::String, findings::AbstractVector{Finding})::Vector{Key}
    definitions = Dict(file.path => Definitions(file) for file in facts.files)
    return [key(definitions[finding.primary.span.file], root, finding) for finding in findings]
end

"""Count per key in baseline file at `root`; empty when file is missing. Malformed file is config error."""
function read_baseline(root::String)::Dict{Key, Int}
    path = joinpath(root, FILE)
    isfile(path) || return Dict{Key, Int}()
    counts = Dict{Key, Int}()
    try
        for table in get(TOML.parsefile(path), "finding", Dict{String, Any}[])
            key, count = entry(table)
            counts[key] = count
        end
    catch error
        throw(ConfigError("$path: $(sprint(showerror, error))"))
    end
    return counts
end

"""Write baseline file at `root` holding `keys`, one entry per distinct key with its count."""
function write_baseline(root::String, keys::AbstractVector{Key})::Nothing
    counts = Dict{Key, Int}()
    foreach(key -> counts[key] = get(counts, key, 0) + 1, keys)
    tables = [
        Dict{String, Any}("rule" => key.rule, "file" => key.file, "definition" => key.definition, "snippet" => key.snippet, "count" => count)
            for (key, count) in sort!(collect(counts); by = pair -> (pair[1].file, pair[1].rule, pair[1].definition, pair[1].snippet))
    ]
    open(joinpath(root, FILE), "w") do io
        println(io, "# Known findings that do not fail run. Rewrite with `corset baseline`; never edit by hand.\n")
        TOML.print(io, Dict("finding" => tables); sorted = true)
    end
    return nothing
end

"""Which of `keys` baseline `counts` covers, in order, and stale keys with counts no finding used."""
function cover(counts::AbstractDict{Key, <:Integer}, keys::AbstractVector{Key})::Tuple{Vector{Bool}, Vector{Key}}
    left = copy(counts)
    covered = map(keys) do key
        get(left, key, 0) > 0 || return false
        left[key] -= 1
        return true
    end
    return covered, sort!([key for (key, count) in left if count > 0]; by = key -> (key.file, key.rule, key.definition))
end

end
