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

"""
Call `visit` on code nodes of `node`, parents first: skips quoted code outside `\$` interpolation.
`quotes` counts open quotes around `node`.
"""
function walk(visit::Function, node::SyntaxNode, quotes::Int = 0)::Nothing
    quotes == 0 && visit(node)
    JS.is_leaf(node) && return nothing
    kind = JS.kind(node)
    inner = kind == JS.K"quote" ? quotes + 1 : kind == JS.K"$" ? max(quotes - 1, 0) : quotes
    foreach(child -> walk(visit, child, inner), JS.children(node))
    return nothing
end


end
