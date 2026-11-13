"""
Opt-out comments, modeled on Rust lint attributes:

- `# corset: allow <rule>, <rule> -- <reason>` after code covers that line.
- Same comment on own line covers next statement: function, struct, block or expression.
- `# corset: allow-file <rule> -- <reason>` before first code covers whole file.

Malformed comment, missing reason, unknown rule, late `allow-file`, and opt-out that suppresses nothing are problems.
Problems always fail run, as rustc fails on unfulfilled `#[expect]` under `-D warnings`.
"""
module OptOuts

using ..Facts: Facts, SyntaxFile, FactSet, Finding, Label, Span, Precision, Confidence

"""Rule name problems report under."""
const NAME = Symbol("opt-out")

"""Level source problems name; problems always have level `deny`."""
const SOURCE = "opt-out check, always on"

"""Comment that addresses Corset; rest of it must follow `GRAMMAR`."""
const ADDRESSED = r"^#\s*corset:"

"""Opt-out grammar: form, comma-separated rule names, optional `--` reason."""
const GRAMMAR = r"^#\s*corset:\s*(?<form>allow-file|allow)\s+(?<rules>[a-z0-9-]+(?:\s*,\s*[a-z0-9-]+)*)\s*(?:--(?<reason>.*))?$"

"""Valid opt-out: rules it allows, comment bytes, and bytes it covers."""
struct OptOut
    rules::Vector{Symbol}
    comment::UnitRange{Int}
    scope::UnitRange{Int}
end

"""Problem finding at comment `bytes` of `file`."""
problem(file::SyntaxFile, bytes::UnitRange{Int}, kind::Symbol, message::String, why::String, fix::String)::Finding = Finding(
    NAME, kind, Confidence.definite, message, Label(Span(file.path, first(bytes), last(bytes), Precision.exact), "opt-out comment"),
    Label[], why, Facts.manual_fix(fix),
)

"""Whether bytes `range` of `file` hold code: anything besides whitespace and comments."""
function holds_code(file::SyntaxFile, range::UnitRange{Int})::Bool
    for index in range
        any(comment -> index in comment, file.comments) && continue
        byte = codeunit(file.text, index)
        byte < 0x80 && isspace(Char(byte)) || return true
    end
    return false
end

"""Bytes of line holding byte `index`, newline excluded."""
function line_bytes(text::String, index::Int)::UnitRange{Int}
    start = something(findprev(==(UInt8('\n')), codeunits(text), index), 0) + 1
    stop = something(findnext(==(UInt8('\n')), codeunits(text), index), ncodeunits(text) + 1) - 1
    return start:stop
end

"""Bytes of outermost statement starting at first code after byte `index`; empty range when no code follows."""
function next_statement(file::SyntaxFile, index::Int)::UnitRange{Int}
    offset = findfirst(byte -> holds_code(file, byte:byte), (index + 1):ncodeunits(file.text))
    isnothing(offset) && return (index + 1):index
    target = index + offset
    stops = [
        last(Facts.trimmed_bytes(file.text, node)) for node in Facts.all_nodes(file)
            if Facts.kind_name(node) != "toplevel" && first(Facts.trimmed_bytes(file.text, node)) == target
    ]
    return target:maximum(stops; init = target)
end

"""Opt-out in comment `bytes` of `file`, problem finding, or `nothing` when comment does not address Corset."""
function read_comment(file::SyntaxFile, bytes::UnitRange{Int}, known::Set{Symbol})::Union{OptOut, Finding, Nothing}
    text = String(codeunits(file.text)[bytes])
    occursin(ADDRESSED, text) || return nothing
    parsed = match(GRAMMAR, text)
    isnothing(parsed) && return problem(
        file, bytes, :malformed, "malformed opt-out comment", "Corset cannot tell which rule comment allows",
        "write `# corset: allow <rule> -- <reason>`",
    )
    isempty(strip(something(parsed[:reason], ""))) && return problem(
        file, bytes, :no_reason, "opt-out gives no reason", "reason tells later readers why finding does not apply",
        "add reason after `--`",
    )
    rules = Symbol.(split(parsed[:rules], r"\s*,\s*"))
    unknown = filter(∉(known), rules)
    isempty(unknown) || return problem(
        file, bytes, :unknown_rule, "opt-out names no rule: `$(join(unknown, "`, `"))`", "misspelled rule name suppresses nothing",
        "use rule name that `corset explain` lists",
    )
    if parsed[:form] == "allow-file"
        holds_code(file, 1:(first(bytes) - 1)) && return problem(
            file, bytes, :late_file, "`allow-file` after code", "file-wide opt-out must open file, so reader sees it first",
            "move comment above first code line",
        )
        return OptOut(rules, bytes, 1:ncodeunits(file.text))
    end
    line = line_bytes(file.text, first(bytes))
    trailing = holds_code(file, first(line):(first(bytes) - 1))
    return OptOut(rules, bytes, trailing ? line : next_statement(file, last(bytes)))
end

"""Findings no opt-out covers, and problems: bad comments plus opt-out rules that suppressed nothing. `known` holds rule names."""
function apply(facts::FactSet, findings::Vector{Finding}, known::Set{Symbol})::Tuple{Vector{Finding}, Vector{Finding}}
    problems = Finding[]
    optouts = Dict(file.path => OptOut[] for file in facts.files)
    for file in facts.files, bytes in file.comments
        read = read_comment(file, bytes, known)
        read isa OptOut && push!(optouts[file.path], read)
        read isa Finding && push!(problems, read)
    end
    kept, used = Finding[], Set{Tuple{String, UnitRange{Int}, Symbol}}()
    for finding in findings
        span = finding.primary.span
        cover = findfirst(optout -> finding.rule in optout.rules && span.first_byte in optout.scope, optouts[span.file])
        isnothing(cover) ? push!(kept, finding) : push!(used, (span.file, optouts[span.file][cover].comment, finding.rule))
    end
    for file in facts.files, optout in optouts[file.path], rule in optout.rules
        (file.path, optout.comment, rule) in used || push!(
            problems, problem(
                file, optout.comment, :unused, "opt-out for `$rule` suppresses nothing",
                "stale opt-out would hide later findings of `$rule` here", "delete `$rule` from comment, or move comment to code it covers",
            )
        )
    end
    return kept, problems
end

end
