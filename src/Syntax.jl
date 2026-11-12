"""`syntax` stage: parse files with JuliaSyntax and index nodes by kind."""
module Syntax

using JuliaSyntax: JuliaSyntax as JS, SyntaxNode, Kind
using ..Facts: SyntaxFile

"""Parse `text` of file `path` into lossless tree with kind index and comment ranges. Parse errors stay in tree as error nodes."""
function parse_file(path::String, text::String)::SyntaxFile
    tree = JS.parseall(SyntaxNode, text; filename = path, ignore_errors = true)
    forms, leaves = Dict{Kind, Vector{SyntaxNode}}(), Dict{Kind, Vector{SyntaxNode}}()
    walk(tree) do node
        push!(get!(() -> SyntaxNode[], JS.is_leaf(node) ? leaves : forms, JS.kind(node)), node)
    end
    comments = [Int(first(token.range)):Int(last(token.range)) for token in JS.tokenize(text) if JS.kind(token) == JS.K"Comment"]
    return SyntaxFile(path, text, tree, forms, leaves, comments)
end

"""Kinds plain Julia code cannot hold; macro argument with one is DSL input that macro rewrites (Argus `{x}`)."""
const DSL_KINDS = (JS.K"braces", JS.K"bracescat")

"""
Call `visit` on code nodes of `node`, parents first. Skips quoted code outside `\$` interpolation
and macro arguments that hold DSL syntax. `quotes` counts open quotes around `node`.
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

"""Whether `node` or any descendant has kind plain Julia code cannot hold."""
holds_dsl(node::SyntaxNode)::Bool = JS.kind(node) in DSL_KINDS || (!JS.is_leaf(node) && any(holds_dsl, JS.children(node)))

end
