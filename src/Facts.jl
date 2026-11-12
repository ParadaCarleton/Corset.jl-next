"""
Fact types and query API. Only module check code may import.

Analyses build facts once per run; checks read them through this module and return `Finding`s.
"""
module Facts

using Argus: Argus, @pattern, Pattern, BindingSet, syntax_match
using EnumX: @enumx
using JuliaSyntax: JuliaSyntax as JS, SyntaxNode, Kind

export Precision, Tier, Confidence, Group, Family
export Span, Label, Edit, Fix, Finding, CheckEntry
export SyntaxFile, FactSet, Rule, Match
export @pattern, matches, binding, span, source, nodes_of_kind, children_of, kind_name
export finding, replace_fix, manual_fix, identifier_name

"""Span precision: `exact` bytes, or `line` when only line is known."""
@enumx Precision exact line
"""Fix risk to callers; one setting picks highest tier applied automatically."""
@enumx Tier safe likely breaking manual
"""`definite`: problem exists. `possible`: analysis could not rule problem out."""
@enumx Confidence definite possible
"""User-facing check group."""
@enumx Group correctness performance composability readability
"""Analysis family that computes facts check reads."""
@enumx Family A B C D E G H

"""Byte range `first_byte:last_byte` of `file`, 1-based and inclusive."""
struct Span
    file::String
    first_byte::Int
    last_byte::Int
    precision::Precision.T
end

"""Span with text rendered under it."""
struct Label
    span::Span
    text::String
end

"""Replace bytes of `span` with `replacement`."""
struct Edit
    span::Span
    replacement::String
end

"""Fix shown under finding. `manual` fix carries no edits."""
struct Fix
    text::String
    edits::Vector{Edit}
    tier::Tier.T
end

"""One problem at one place. `message` is headline; `why` explains harm."""
struct Finding
    check::Symbol
    kind::Symbol
    confidence::Confidence.T
    message::String
    primary::Label
    causes::Vector{Label}
    why::String
    fix::Union{Fix, Nothing}
end

"""Registry entry: check metadata plus pure function `run(facts::FactSet)::Vector{Finding}`."""
struct CheckEntry
    name::Symbol
    group::Group.T
    footguns::Vector{Int}
    family::Family.T
    run::Function
end

"""Parsed source file: lossless tree plus nodes indexed by kind (family A facts)."""
struct SyntaxFile
    path::String
    text::String
    tree::SyntaxNode
    index::Dict{Kind, Vector{SyntaxNode}}
end

"""Facts of one run."""
struct FactSet
    files::Vector{SyntaxFile}
end

"""Argus pattern plus kinds its root can take; `nothing` means any kind."""
struct Rule
    pattern::Pattern
    root_kinds::Union{Nothing, Vector{Kind}}
end

"""Rule for `pattern`, indexed by kinds of its root alternatives."""
Rule(pattern::Pattern) = Rule(pattern, root_kinds(pattern.src))

"""Kinds `node` of pattern can match at root; `nothing` when pattern variable sits at root."""
function root_kinds(node)::Union{Nothing, Vector{Kind}}
    name = kind_name(node)
    name == "~or" || return startswith(name, "~") ? nothing : [JS.kind(node)]
    alternatives = map(root_kinds, JS.children(node))
    any(isnothing, alternatives) && return nothing
    return unique(reduce(vcat, alternatives))
end

"""Name of node kind as string; Argus pattern forms start with `~`."""
kind_name(node)::String = string(JS.kind(node))

"""Successful match of rule at `node` with its pattern variable bindings."""
struct Match
    node::SyntaxNode
    bindings::BindingSet
end

"""Nodes of `file` with kind `kind`, in source order."""
nodes_of_kind(file::SyntaxFile, kind::Kind)::Vector{SyntaxNode} = get(file.index, kind, SyntaxNode[])

"""Every match of `rule` in `file`, in source order. Tries only nodes whose kind rule root can take."""
function matches(file::SyntaxFile, rule::Rule)::Vector{Match}
    candidates = isnothing(rule.root_kinds) ? reduce(vcat, values(file.index); init = SyntaxNode[]) :
        reduce(vcat, (nodes_of_kind(file, kind) for kind in rule.root_kinds); init = SyntaxNode[])
    found = Match[]
    for node in sort!(unique!(candidates); by = JS.first_byte)
        result = syntax_match(rule.pattern, node)
        result isa BindingSet && push!(found, Match(node, result))
    end
    return found
end

"""Syntax node bound to pattern variable `name` in `match`."""
binding(match::Match, name::Symbol)::SyntaxNode = match.bindings[name].src

"""Byte range of `node` in `file` without surrounding whitespace; infix nodes start at leading trivia."""
function trimmed_bytes(file::SyntaxFile, node::SyntaxNode)::UnitRange{Int}
    bytes = codeunits(file.text)
    first, last = JS.first_byte(node), JS.last_byte(node)
    while first < last && bytes[first] in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
        first += 1
    end
    while last > first && bytes[last] in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
        last -= 1
    end
    return first:last
end

"""Exact span of `node` in `file`."""
function span(file::SyntaxFile, node::SyntaxNode)::Span
    bytes = trimmed_bytes(file, node)
    return Span(file.path, first(bytes), last(bytes), Precision.exact)
end

"""Source text of `node` in `file`."""
function source(file::SyntaxFile, node::SyntaxNode)::String
    bytes = trimmed_bytes(file, node)
    return file.text[first(bytes):thisind(file.text, last(bytes))]
end

"""Name of identifier `node`; `nothing` for other kinds."""
identifier_name(node::SyntaxNode)::Union{Nothing, String} = kind_name(node) == "Identifier" ? string(node.val) : nothing

"""Children of `node`; empty for leaf."""
children_of(node::SyntaxNode)::Vector{SyntaxNode} = JS.is_leaf(node) ? SyntaxNode[] : collect(JS.children(node))

"""Finding of `check` with primary label at `node` of `file`."""
function finding(
        check::Symbol, file::SyntaxFile, node::SyntaxNode; kind::Symbol, confidence::Confidence.T, message::String,
        label::String, why::String, fix::Union{Fix, Nothing}, causes::Vector{Label} = Label[],
    )::Finding
    return Finding(check, kind, confidence, message, Label(span(file, node), label), causes, why, fix)
end

"""Fix replacing `node` of `file` with `replacement`."""
replace_fix(file::SyntaxFile, node::SyntaxNode, replacement::String, tier::Tier.T)::Fix =
    Fix("replace with `$replacement`", [Edit(span(file, node), replacement)], tier)

"""Fix with no edits; shown, never applied."""
manual_fix(text::String)::Fix = Fix(text, Edit[], Tier.manual)

end
