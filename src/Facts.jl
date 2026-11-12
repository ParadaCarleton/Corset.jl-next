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

"""
Argus pattern plus filter on root nodes it can match: kind, then call head for `call` roots.
`nothing` filter means pattern variable sits at root; head set `nothing` means any head.
"""
struct Rule
    pattern::Pattern
    roots::Union{Nothing, Dict{Kind, Union{Nothing, Set{String}}}}
end

"""Rule for `pattern`, indexed by root alternatives."""
function Rule(pattern::Pattern)
    alternatives = root_alternatives(pattern.src)
    any(node -> startswith(kind_name(node), "~"), alternatives) && return Rule(pattern, nothing)
    roots = Dict{Kind, Union{Nothing, Set{String}}}()
    for node in alternatives
        kind, head = JS.kind(node), call_head(node)
        previous = get(roots, kind, Set{String}())
        roots[kind] = isnothing(head) || isnothing(previous) ? nothing : push!(previous, head)
    end
    return Rule(pattern, roots)
end

"""Root nodes of pattern, with `~or` alternatives flattened."""
root_alternatives(node)::Vector{Any} =
    kind_name(node) == "~or" ? reduce(vcat, map(root_alternatives, JS.children(node))) : Any[node]

"""Function name of call `node` (operator for infix call); `nothing` for other nodes or computed callee."""
function call_head(node)::Union{Nothing, String}
    kind_name(node) == "call" || return nothing
    callee = JS.children(node)[JS.is_infix_op_call(node) ? 2 : 1]
    return kind_name(callee) == "Identifier" ? string(callee.val) : nothing
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

"""Every match of `rule` in `file`, in source order. Tries only nodes whose kind and call head rule root can take."""
function matches(file::SyntaxFile, rule::Rule)::Vector{Match}
    found = Match[]
    if isnothing(rule.roots)
        for nodes in values(file.index), node in nodes
            try_match!(found, rule, node)
        end
    else
        for (kind, heads) in rule.roots, node in nodes_of_kind(file, kind)
            isnothing(heads) || call_head(node) in heads || continue
            try_match!(found, rule, node)
        end
    end
    return sort!(found; by = match -> JS.first_byte(match.node))
end

"""Push match of `rule` at `node` to `found` when pattern matches."""
function try_match!(found::Vector{Match}, rule::Rule, node::SyntaxNode)::Nothing
    result = syntax_match(rule.pattern, node)
    result isa BindingSet && push!(found, Match(node, result))
    return nothing
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
