"""
Fact types and query API. Only module rule code may import.

Analyses build facts once per run; rules read them through this module and return `Finding`s.
`SyntaxNode` `==` and `hash` walk whole subtree: compare nodes with `===`, key collections by `objectid`.
"""
module Facts

using Argus: Argus, @pattern, Pattern, BindingSet, syntax_match
using EnumX: @enumx
using JuliaSyntax: JuliaSyntax as JS, SyntaxNode, Kind
using ReadOnlyArrays: ReadOnlyVector

export Precision, Tier, Confidence, Group, Stage, Role
export Span, Label, Edit, Fix, Finding, BlindSpot, RuleEntry
export SyntaxFile, SyntaxNode, FactSet, IndexedPattern, Match
export @pattern, matches, binding, span, source, all_nodes, forms, leaves, children_of, kind_name
export finding, replace_fix, manual_fix, identifier_name, parent_of, ancestors, descendants, call_head, leaf_value
export definition_name, struct_fields, include_calls, include_target

"""Span precision: `exact` bytes, or `line` when only line is known."""
@enumx Precision exact line
"""Fix risk to callers; one setting picks highest tier applied automatically."""
@enumx Tier safe likely breaking manual
"""`definite`: problem exists. `possible`: compiler cannot resolve doubt either."""
@enumx Confidence definite possible
"""User-facing rule group."""
@enumx Group correctness performance composability readability
"""Analysis stage that computes facts rule reads, in pipeline order."""
@enumx Stage syntax package scope inference effects lifecycle external
"""File role: `package` module code precompiles; `script` code (tests, docs, scripts) runs each time it loads."""
@enumx Role package script

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
    rule::Symbol
    kind::Symbol
    confidence::Confidence.T
    message::String
    primary::Label
    causes::Vector{Label}
    why::String
    fix::Union{Fix, Nothing}
end

"""Site Corset skipped though compiler resolves it; coverage line counts it by `cause`."""
struct BlindSpot
    cause::String
    span::Span
end

"""Registry entry: rule metadata plus pure function `run(facts::FactSet)::Vector{Finding}`."""
struct RuleEntry
    name::Symbol
    group::Group.T
    footguns::Vector{Int}
    stage::Stage.T
    run::Function
end

"""
Parsed source file (`syntax` stage facts): role, lossless tree, comment byte ranges, and code nodes indexed by kind.
Index keeps forms (inner nodes) apart from leaves, since quoted operators like `:(=)` are leaves of form kinds.
Index skips quoted code outside interpolation and macro arguments with `{}` (`Syntax.walk`); tree walks see both.
`groups` maps node to bytes of grouping parentheses that wrap only it (`Syntax.groups`).
`parse_errors` label each JuliaSyntax parse error; tree holds recovered code there.
"""
struct SyntaxFile
    path::String
    text::String
    role::Role.T
    tree::SyntaxNode
    forms::Dict{Kind, Vector{SyntaxNode}}
    leaves::Dict{Kind, Vector{SyntaxNode}}
    comments::Vector{UnitRange{Int}}
    groups::IdDict{SyntaxNode, UnitRange{Int}}
    parse_errors::Vector{Label}
end

"""Facts of one run: parsed files, and entry files Julia loads directly (empty for directory walk, where any file may be included)."""
struct FactSet
    files::Vector{SyntaxFile}
    entries::Vector{String}
end

"""
Argus pattern plus filter on root nodes it can match: kind, then call head for `call` roots.
`nothing` filter means pattern variable sits at root; head set `nothing` means any head.
"""
struct IndexedPattern
    pattern::Pattern
    roots::Union{Nothing, Dict{Kind, Union{Nothing, Set{String}}}}
end

"""`pattern` indexed by root alternatives, so matcher tries only candidate nodes."""
function IndexedPattern(pattern::Pattern)::IndexedPattern
    alternatives = root_alternatives(pattern.src)
    any(node -> startswith(kind_name(node), "~"), alternatives) && return IndexedPattern(pattern, nothing)
    roots = Dict{Kind, Union{Nothing, Set{String}}}()
    for node in alternatives
        kind, head = JS.kind(node), call_head(node)
        previous = get(roots, kind, Set{String}())
        roots[kind] = isnothing(head) || isnothing(previous) ? nothing : push!(previous, head)
    end
    return IndexedPattern(pattern, roots)
end

"""Root nodes of pattern, with `~or` alternatives flattened."""
root_alternatives(node::JS.TreeNode)::Vector{Any} =
    kind_name(node) == "~or" ? reduce(vcat, map(root_alternatives, JS.children(node))) : Any[node]

"""Function name of call `node` (operator for infix call); `nothing` for other nodes or computed callee."""
function call_head(node::JS.TreeNode)::Union{Nothing, String}
    kind_name(node) == "call" || return nothing
    callee = JS.children(node)[JS.is_infix_op_call(node) ? 2 : 1]
    return kind_name(callee) == "Identifier" ? string(callee.val) : nothing
end

"""Functions that load file into calling module: Base `include`, Revise `includet`."""
const INCLUDES = ("include", "includet")

"""Calls of `file` that load another file."""
include_calls(file::SyntaxFile)::Vector{SyntaxNode} = filter(call -> call_head(call) in INCLUDES, forms(file, "call"))

"""Absolute path include `call` in `file` loads; `nothing` when path is computed."""
function include_target(file::SyntaxFile, call::SyntaxNode)::Union{Nothing, String}
    parts = path_parts(file, children_of(call)[end])
    return isnothing(parts) ? nothing : normpath(joinpath(dirname(file.path), parts...))
end

"""Path pieces of `node`: string literal, `raw` string, `@__DIR__`, or `joinpath` of those; `nothing` for anything else."""
function path_parts(file::SyntaxFile, node::SyntaxNode)::Union{Nothing, Vector{String}}
    pieces = children_of(node)
    kind_name(node) == "string" && length(pieces) == 1 && kind_name(pieces[1]) == "String" && return [leaf_value(pieces[1])]
    kind_name(node) == "macrocall" && leaf_value(pieces[1]) == "@raw_str" && return path_parts(file, pieces[2])
    kind_name(node) == "macrocall" && leaf_value(pieces[1]) == "@__DIR__" && return [dirname(file.path)]
    call_head(node) == "joinpath" || return nothing
    parts = [path_parts(file, piece) for piece in pieces[2:end]]
    return any(isnothing, parts) ? nothing : reduce(vcat, parts; init = String[])
end

"""Name of node kind as string; Argus pattern forms start with `~`."""
kind_name(node::JS.TreeNode)::String = string(JS.kind(node))

"""Successful match of pattern at `node` with its pattern variable bindings."""
struct Match
    node::SyntaxNode
    bindings::BindingSet
end

"""Forms (inner nodes) of `file` whose kind is named `name` (`"="`, `"catch"`), in source order."""
forms(file::SyntaxFile, name::String)::Vector{SyntaxNode} = get(file.forms, Kind(name), SyntaxNode[])

"""Leaves of `file` whose kind is named `name` (`"Identifier"`, `"Integer"`), in source order."""
leaves(file::SyntaxFile, name::String)::Vector{SyntaxNode} = get(file.leaves, Kind(name), SyntaxNode[])

"""Every node of `file`: forms, then leaves."""
all_nodes(file::SyntaxFile)::Vector{SyntaxNode} = [node for index in (file.forms, file.leaves) for nodes in values(index) for node in nodes]

"""Every match of `indexed` in `file`, in source order. Tries only nodes whose kind and call head pattern root can take."""
function matches(file::SyntaxFile, indexed::IndexedPattern)::Vector{Match}
    found = Match[]
    if isnothing(indexed.roots)
        foreach(node -> try_match!(found, indexed, node), all_nodes(file))
    else
        for (kind, heads) in indexed.roots, index in (file.forms, file.leaves), node in get(index, kind, SyntaxNode[])
            isnothing(heads) || call_head(node) in heads || continue
            try_match!(found, indexed, node)
        end
    end
    return sort!(found; by = match -> JS.first_byte(match.node))
end

"""Push match of `indexed` at `node` to `found` when pattern matches."""
function try_match!(found::Vector{Match}, indexed::IndexedPattern, node::SyntaxNode)::Nothing
    result = syntax_match(indexed.pattern, node)
    result isa BindingSet && push!(found, Match(node, result))
    return nothing
end

"""Syntax node bound to pattern variable `name` in `match`."""
binding(match::Match, name::Symbol)::SyntaxNode = match.bindings[name].src

"""`range` of bytes in `text` without surrounding whitespace."""
function trimmed(text::String, range::UnitRange{Int})::UnitRange{Int}
    bytes = codeunits(text)
    first, last = range.start, range.stop
    while first < last && bytes[first] in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
        first += 1
    end
    while last > first && bytes[last] in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
        last -= 1
    end
    return first:last
end

"""Byte range of `node` in `text` without surrounding whitespace; infix nodes start at leading trivia."""
trimmed_bytes(text::String, node::SyntaxNode)::UnitRange{Int} = trimmed(text, JS.first_byte(node):JS.last_byte(node))

"""Exact span of `node` in `file`."""
function span(file::SyntaxFile, node::SyntaxNode)::Span
    bytes = trimmed_bytes(file.text, node)
    return Span(file.path, first(bytes), last(bytes), Precision.exact)
end

"""Source text of `node` in `file` with grouping parentheses that wrap only it; safe to paste in new context."""
function source(file::SyntaxFile, node::SyntaxNode)::String
    bytes = get(() -> trimmed_bytes(file.text, node), file.groups, node)
    return file.text[first(bytes):thisind(file.text, last(bytes))]
end

"""Name of identifier `node`; `nothing` for other kinds."""
identifier_name(node::SyntaxNode)::Union{Nothing, String} = kind_name(node) == "Identifier" ? string(node.val) : nothing

"""Parent of `node`; `nothing` at root."""
parent_of(node::SyntaxNode)::Union{Nothing, SyntaxNode} = node.parent

"""Strict ancestors of `node`, nearest first."""
function ancestors(node::SyntaxNode)::Vector{SyntaxNode}
    found = SyntaxNode[]
    current = node.parent
    while !isnothing(current)
        push!(found, current)
        current = current.parent
    end
    return found
end

"""`node` and every descendant, parents first."""
function descendants(node::SyntaxNode)::Vector{SyntaxNode}
    found = SyntaxNode[node]
    for child in children_of(node)
        append!(found, descendants(child))
    end
    return found
end

"""Value of leaf `node` as string (`"@ccall"` for macro name); `nothing` for inner node."""
leaf_value(node::SyntaxNode)::Union{Nothing, String} = JS.is_leaf(node) ? string(node.val) : nothing

"""Children of leaf."""
const NO_CHILDREN = ReadOnlyVector(SyntaxNode[])

"""Children of `node`, read-only and without copy; empty for leaf."""
children_of(node::SyntaxNode)::ReadOnlyVector{SyntaxNode, Vector{SyntaxNode}} =
    JS.is_leaf(node) ? NO_CHILDREN : ReadOnlyVector(JS.children(node))

"""Name node of definition `node` (function, macro, struct, module): strips `where`, result type, arguments, type parameters, supertype."""
function definition_name(node::SyntaxNode)::SyntaxNode
    head = children_of(node)[1]
    while kind_name(head) in ("where", "::", "call", "curly", "<:") && !isempty(children_of(head))
        head = children_of(head)[1]
    end
    return head
end

"""Field name nodes of struct definition `definition`, skipping inner constructors."""
function struct_fields(definition::SyntaxNode)::Vector{SyntaxNode}
    names = SyntaxNode[]
    for field in children_of(children_of(definition)[end])
        node = kind_name(field) == "=" ? children_of(field)[1] : field
        node = kind_name(node) == "::" ? children_of(node)[1] : node
        isnothing(identifier_name(node)) || push!(names, node)
    end
    return names
end

"""Finding of `rule` with primary label at `node` of `file`."""
function finding(
        rule::Symbol, file::SyntaxFile, node::SyntaxNode; kind::Symbol, confidence::Confidence.T, message::String,
        label::String, why::String, fix::Union{Fix, Nothing}, causes::Vector{Label} = Label[],
    )::Finding
    return Finding(rule, kind, confidence, message, Label(span(file, node), label), causes, why, fix)
end

"""Fix replacing `node` of `file` with `replacement`."""
replace_fix(file::SyntaxFile, node::SyntaxNode, replacement::String, tier::Tier.T)::Fix =
    Fix("replace with `$replacement`", [Edit(span(file, node), replacement)], tier)

"""Fix with no edits; shown, never applied."""
manual_fix(text::String)::Fix = Fix(text, Edit[], Tier.manual)

end
