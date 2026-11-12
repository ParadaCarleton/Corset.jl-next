"""
Spike S4: syntax pattern matcher on JuliaSyntax green trees.

Write pattern as Julia syntax with holes: `_x` binds one node, `_` matches any node, `_xs...` binds zero or more siblings.
Repeated named hole matches structurally equal subtrees.
"""
module S4Matcher

using JuliaSyntax: JuliaSyntax as JS, GreenNode, SyntaxHead, Kind, @K_str

export Red, Pattern, Rule, Finding, compile_pattern, match_pattern, run_rules, parse_file, node_text, node_range, callee_name, contains_match

const Green = GreenNode{SyntaxHead}

"""Red node: green node plus absolute 0-based byte offset into source."""
struct Red
    green::Green
    offset::Int
end

JS.kind(r::Red)::Kind = JS.kind(r.green)

"""Non-trivia children of `r`, with infix call operator moved first."""
function significant_children(r::Red)::Vector{Red}
    out = Red[]
    JS.is_leaf(r.green) && return out
    position = r.offset
    for child in JS.children(r.green)
        JS.is_trivia(child) || push!(out, Red(child, position))
        position += JS.span(child)
    end
    if JS.kind(r) == K"call" && JS.is_infix_op_call(JS.head(r.green)) && length(out) == 3
        out[1], out[2] = out[2], out[1]
    end
    return out
end

"""Drop redundant parentheses around `r`."""
function unwrap_parens(r::Red)::Red
    while JS.kind(r) == K"parens"
        inner = significant_children(r)
        length(inner) == 1 || return r
        r = only(inner)
    end
    return r
end

"""Byte range of `r` without leading and trailing trivia, 1-based."""
function node_range(r::Red)::UnitRange{Int}
    JS.is_leaf(r.green) && return (r.offset + 1):(r.offset + JS.span(r.green))
    inner = Red[]
    position = r.offset
    for child in JS.children(r.green)
        JS.kind(child) in KSet_TRIVIAL || push!(inner, Red(child, position))
        position += JS.span(child)
    end
    isempty(inner) && return (r.offset + 1):(r.offset + JS.span(r.green))
    return first(node_range(first(inner))):last(node_range(last(inner)))
end

const KSet_TRIVIAL = (K"Whitespace", K"NewlineWs", K"Comment")

"""Source text of `r` without surrounding trivia."""
node_text(src::String, r::Red)::SubString{String} = (rng = node_range(r); SubString(src, first(rng), thisind(src, last(rng))))

"""Whether leaf `r` spells `text` in `bytes`; no allocation."""
function leaf_spells(bytes::AbstractVector{UInt8}, r::Red, text::String)::Bool
    JS.span(r.green) == ncodeunits(text) || return false
    @inbounds for i in 1:ncodeunits(text)
        bytes[r.offset + i] == codeunit(text, i) || return false
    end
    return true
end

abstract type Pattern end

"""Hole `_name`; `_` never binds."""
struct Hole <: Pattern
    name::Symbol
end

"""Sequence hole `_name...`: zero or more siblings."""
struct SeqHole <: Pattern
    name::Symbol
end

struct Leaf <: Pattern
    kind::Kind
    text::String
end

struct Node <: Pattern
    kind::Kind
    children::Vector{Pattern}
end

root_kind(p::Node)::Kind = p.kind
root_kind(p::Leaf)::Kind = p.kind

"""Compile pattern source into pattern tree; throw on parse error or bare hole root."""
function compile_pattern(source::String)::Pattern
    green = JS.parsestmt(GreenNode, source)
    pattern = to_pattern(source, unwrap_parens(Red(green, 0)))
    pattern isa Union{Node, Leaf} || throw(ArgumentError("pattern root must be concrete syntax: $source"))
    return pattern
end

is_hole_name(text::AbstractString)::Bool = startswith(text, '_')

function to_pattern(source::String, r::Red)::Pattern
    k = JS.kind(r)
    k == K"error" && throw(ArgumentError("pattern does not parse: $source"))
    if JS.is_leaf(r.green)
        text = node_text(source, r)
        k == K"Identifier" && is_hole_name(text) && return Hole(Symbol(text))
        return Leaf(k, String(text))
    end
    inner = significant_children(r)
    if k == K"..." && length(inner) == 1 && JS.kind(only(inner)) == K"Identifier" && is_hole_name(node_text(source, only(inner)))
        return SeqHole(Symbol(node_text(source, only(inner))))
    end
    return Node(k, Pattern[to_pattern(source, c) for c in inner])
end

"""Match state: bindings stack (truncated on backtrack) and source bytes."""
struct MatchState
    src::String
    bytes::Base.CodeUnits{UInt8, String}
    singles::Vector{Pair{Symbol, Red}}
    sequences::Vector{Pair{Symbol, Vector{Red}}}
end

MatchState(src::String)::MatchState = MatchState(src, codeunits(src), Pair{Symbol, Red}[], Pair{Symbol, Vector{Red}}[])

"""Bindings of one successful match."""
struct Bindings
    src::String
    singles::Dict{Symbol, Red}
    sequences::Dict{Symbol, Vector{Red}}
end

Base.getindex(b::Bindings, name::Symbol)::Red = b.singles[name]
sequence(b::Bindings, name::Symbol)::Vector{Red} = b.sequences[name]
export sequence, Bindings

"""Whether `a` and `b` are same syntax, ignoring trivia."""
function same_syntax(state::MatchState, a::Red, b::Red)::Bool
    a, b = unwrap_parens(a), unwrap_parens(b)
    JS.kind(a) == JS.kind(b) || return false
    if JS.is_leaf(a.green) || JS.is_leaf(b.green)
        return JS.is_leaf(a.green) && JS.is_leaf(b.green) && node_text(state.src, a) == node_text(state.src, b)
    end
    ca, cb = significant_children(a), significant_children(b)
    length(ca) == length(cb) || return false
    return all(same_syntax(state, x, y) for (x, y) in zip(ca, cb))
end

function bound(stack::Vector{Pair{Symbol, T}}, name::Symbol)::Union{Nothing, T} where {T}
    for (key, node) in Iterators.reverse(stack)
        key === name && return node
    end
    return nothing
end

function match!(state::MatchState, p::Hole, r::Red)::Bool
    p.name === :_ && return true
    previous = bound(state.singles, p.name)
    isnothing(previous) || return same_syntax(state, previous, r)
    push!(state.singles, p.name => r)
    return true
end

function match!(state::MatchState, p::Leaf, r::Red)::Bool
    r = unwrap_parens(r)
    return JS.kind(r) == p.kind && JS.is_leaf(r.green) && leaf_spells(state.bytes, r, p.text)
end

function match!(state::MatchState, p::Node, r::Red)::Bool
    p.kind == K"parens" || (r = unwrap_parens(r))
    (JS.kind(r) == p.kind && !JS.is_leaf(r.green)) || return false
    return match_siblings!(state, p.children, 1, significant_children(r), 1)
end

match!(::MatchState, p::SeqHole, ::Red)::Bool = throw(ArgumentError("sequence hole $(p.name) outside sibling list"))

"""Match patterns `ps[i:end]` against nodes `rs[j:end]`, backtracking over sequence holes."""
function match_siblings!(state::MatchState, ps::Vector{Pattern}, i::Int, rs::Vector{Red}, j::Int)::Bool
    i > length(ps) && return j > length(rs)
    p = ps[i]
    if p isa SeqHole
        for stop in (j - 1):length(rs)
            mark = (length(state.singles), length(state.sequences))
            p.name === :_ || push!(state.sequences, p.name => rs[j:stop])
            match_siblings!(state, ps, i + 1, rs, stop + 1) && return true
            truncate!(state, mark)
        end
        return false
    end
    j > length(rs) && return false
    mark = (length(state.singles), length(state.sequences))
    match!(state, p, rs[j]) && match_siblings!(state, ps, i + 1, rs, j + 1) && return true
    truncate!(state, mark)
    return false
end

function truncate!(state::MatchState, mark::Tuple{Int, Int})::Nothing
    resize!(state.singles, mark[1])
    resize!(state.sequences, mark[2])
    return nothing
end

"""Bindings when `pattern` matches `r` in `src`, else `nothing`."""
function match_pattern(pattern::Pattern, src::String, r::Red)::Union{Nothing, Bindings}
    state = MatchState(src)
    match!(state, pattern, r) || return nothing
    return Bindings(src, Dict(state.singles), Dict(state.sequences))
end

"""Whether any node under `r` matches `pattern` after pre-binding `fixed` holes."""
function contains_match(pattern::Pattern, b::Bindings, r::Red; fixed::Vector{Symbol})::Bool
    state = MatchState(b.src)
    found = Ref(false)
    walk(r) do node
        found[] && return
        resize!(state.singles, 0)
        append!(state.singles, [name => b[name] for name in fixed])
        resize!(state.sequences, 0)
        found[] = match!(state, pattern, node)
    end
    return found[]
end

"""Call `visit(node)` on `r` and every descendant, pre-order."""
function walk(visit::F, r::Red)::Nothing where {F}
    visit(r)
    JS.is_leaf(r.green) && return nothing
    position = r.offset
    for child in JS.children(r.green)
        JS.is_trivia(child) || walk(visit, Red(child, position))
        position += JS.span(child)
    end
    return nothing
end

"""Call `visit(node, ancestors)` pre-order; `ancestors` holds enclosing nodes, outermost first."""
function walk_ancestors(visit::F, r::Red, ancestors::Vector{Red} = Red[])::Nothing where {F}
    visit(r, ancestors)
    JS.is_leaf(r.green) && return nothing
    push!(ancestors, r)
    position = r.offset
    for child in JS.children(r.green)
        JS.is_trivia(child) || walk_ancestors(visit, Red(child, position), ancestors)
        position += JS.span(child)
    end
    pop!(ancestors)
    return nothing
end

"""Name of called function: `f` in `f(x)`, `Vector` in `Vector{T}(x)`, `threadid` in `Threads.threadid()`."""
function callee_name(src::String, r::Red)::Union{Nothing, SubString{String}}
    r = unwrap_parens(r)
    k = JS.kind(r)
    k == K"Identifier" && return node_text(src, r)
    k in (K"curly", K".") || return nothing
    inner = significant_children(r)
    isempty(inner) && return nothing
    return callee_name(src, k == K"." ? last(inner) : first(inner))
end

"""Lint rule: footgun id, alternative patterns, guard `(bindings, node, ancestors) -> Bool`, message."""
struct Rule{G}
    footgun::Int
    name::String
    patterns::Vector{Pattern}
    guard::G
    message::String
end

Rule(footgun::Int, name::String, patterns::Vector{String}, guard, message::String) =
    Rule(footgun, name, Pattern[compile_pattern(p) for p in patterns], guard, message)

struct Finding
    footgun::Int
    rule::String
    file::String
    line::Int
    range::UnitRange{Int}
    text::String
end

"""Parse `src` losslessly; parse errors stay in tree as error nodes."""
parse_file(src::String)::Red = Red(JS.parseall(GreenNode, src; ignore_errors = true), 0)

"""One walk over `tree`; each node tries only patterns whose root kind matches."""
function run_rules(rules::Vector{<:Rule}, file::String, src::String, tree::Red)::Vector{Finding}
    index = Dict{Kind, Vector{Tuple{Int, Pattern}}}()
    for (ri, rule) in enumerate(rules), p in rule.patterns
        push!(get!(Vector{Tuple{Int, Pattern}}, index, root_kind(p)), (ri, p))
    end
    findings = Finding[]
    source_file = JS.SourceFile(src)
    state = MatchState(src)
    walk_ancestors(tree) do node, ancestors
        candidates = get(index, JS.kind(node), nothing)
        isnothing(candidates) && return
        for (ri, p) in candidates
            truncate!(state, (0, 0))
            match!(state, p, node) || continue
            rule = rules[ri]
            b = Bindings(src, Dict(state.singles), Dict(state.sequences))
            rule.guard(b, node, ancestors)::Bool || continue
            rng = node_range(node)
            push!(findings, Finding(rule.footgun, rule.name, file, JS.source_line(source_file, first(rng)), rng, String(node_text(src, node))))
            break
        end
    end
    return findings
end

end
