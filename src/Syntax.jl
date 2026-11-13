"""`syntax` stage: parse files with JuliaSyntax and index nodes by kind."""
module Syntax

using JuliaSyntax: JuliaSyntax as JS, SyntaxNode, Kind
using ..Facts: SyntaxFile, trimmed, trimmed_bytes

"""Parse `text` of file `path` into lossless tree with kind index and comment ranges. Parse errors stay in tree as error nodes."""
function parse_file(path::String, text::String)::SyntaxFile
    tree = JS.parseall(SyntaxNode, text; filename = path, ignore_errors = true)
    forms, leaves = Dict{Kind, Vector{SyntaxNode}}(), Dict{Kind, Vector{SyntaxNode}}()
    walk(tree) do node
        push!(get!(() -> SyntaxNode[], JS.is_leaf(node) ? leaves : forms, JS.kind(node)), node)
    end
    comments = [Int(first(token.range)):Int(last(token.range)) for token in JS.tokenize(text) if JS.kind(token) == JS.K"Comment"]
    return SyntaxFile(path, text, tree, forms, leaves, comments, groups!(IdDict{SyntaxNode, UnitRange{Int}}(), text, tree))
end

"""
Record in `found` bytes of grouping parentheses that wrap only one child of `node` and its descendants.
JuliaSyntax keeps them as `parens` green children of parent and drops them from `SyntaxNode` tree.
"""
function groups!(found::IdDict{SyntaxNode, UnitRange{Int}}, text::String, node::SyntaxNode)::IdDict{SyntaxNode, UnitRange{Int}}
    JS.is_leaf(node) && return found
    children, index, offset = JS.children(node), 1, JS.first_byte(node)
    for green in JS.children(node.raw)
        range = offset:(offset + JS.span(green) - 1)
        offset += JS.span(green)
        JS.kind(green) == JS.K"parens" || continue
        inner = content(text, green, first(range))
        isnothing(inner) && continue
        # Children and parens both follow source order, so one pass pairs them.
        while index <= length(children) && first(trimmed_bytes(text, children[index])) < first(inner)
            index += 1
        end
        index <= length(children) && trimmed_bytes(text, children[index]) == inner && (found[children[index]] = range)
    end
    foreach(child -> groups!(found, text, child), children)
    return found
end

"""Bytes of only code inside `parens` node `green` at byte `offset`, through nested parentheses; `nothing` for other contents."""
function content(text::String, green::JS.GreenNode, offset::Int)::Union{Nothing, UnitRange{Int}}
    parts = Tuple{JS.GreenNode, Int}[]
    for part in JS.children(green)
        JS.is_trivia(part) || push!(parts, (part, offset))
        offset += JS.span(part)
    end
    length(parts) == 1 || return nothing
    part, start = only(parts)
    return JS.kind(part) == JS.K"parens" ? content(text, part, start) : trimmed(text, start:(start + JS.span(part) - 1))
end

"""
Kinds lowering always rejects; macro argument with one is DSL input (Argus `{x}`).
Stopgap: plan.md later row replaces it with check for any code Julia rejects as written.
"""
const DSL_KINDS = (JS.K"braces", JS.K"bracescat")

"""
Call `visit` on code nodes of `node`, parents first. Skips quoted code outside `\$` interpolation
and macro arguments that hold `DSL_KINDS`. `quotes` counts open quotes around `node`.
"""
function walk(visit::Function, node::SyntaxNode, quotes::Int = 0)::Nothing
    quotes == 0 && visit(node)
    JS.is_leaf(node) && return nothing
    kind = JS.kind(node)
    inner = kind == JS.K"quote" ? quotes + 1 : kind == JS.K"$" ? max(quotes - 1, 0) : quotes
    for (position, child) in enumerate(JS.children(node))
        kind == JS.K"macrocall" && position > 1 && holds_dsl(child) && continue
        walk(visit, child, inner)
    end
    return nothing
end

"""Whether `node` or any descendant has kind in `DSL_KINDS`."""
holds_dsl(node::SyntaxNode)::Bool = JS.kind(node) in DSL_KINDS || (!JS.is_leaf(node) && any(holds_dsl, JS.children(node)))

end
