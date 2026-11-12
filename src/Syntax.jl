"""`syntax` stage: parse files with JuliaSyntax and index nodes by kind."""
module Syntax

using JuliaSyntax: JuliaSyntax as JS, SyntaxNode, Kind
using ..Facts: SyntaxFile

"""Parse `text` of file `path` into lossless tree with kind index and comment ranges. Parse errors stay in tree as error nodes."""
function parse_file(path::String, text::String)::SyntaxFile
    tree = JS.parseall(SyntaxNode, text; filename = path, ignore_errors = true)
    index = Dict{Kind, Vector{SyntaxNode}}()
    walk(tree) do node
        push!(get!(() -> SyntaxNode[], index, JS.kind(node)), node)
    end
    comments = [Int(first(token.range)):Int(last(token.range)) for token in JS.tokenize(text) if JS.kind(token) == JS.K"Comment"]
    return SyntaxFile(path, text, tree, index, comments)
end

"""Call `visit` on `node` and every descendant, parents first."""
function walk(visit::Function, node::SyntaxNode)::Nothing
    visit(node)
    JS.is_leaf(node) || foreach(child -> walk(visit, child), JS.children(node))
    return nothing
end

end
