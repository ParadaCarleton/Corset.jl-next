"""L1: parse files with JuliaSyntax and index nodes by kind (family A facts)."""
module Syntax

using JuliaSyntax: JuliaSyntax as JS, SyntaxNode, Kind
using ..Facts: SyntaxFile

"""Parse `text` of file `path` into lossless tree with kind index. Parse errors stay in tree as error nodes."""
function parse_file(path::String, text::String)::SyntaxFile
    tree = JS.parseall(SyntaxNode, text; filename = path, ignore_errors = true)
    index = Dict{Kind, Vector{SyntaxNode}}()
    walk(tree) do node
        push!(get!(() -> SyntaxNode[], index, JS.kind(node)), node)
    end
    return SyntaxFile(path, text, tree, index)
end

"""Call `visit` on `node` and every descendant, parents first."""
function walk(visit::Function, node::SyntaxNode)::Nothing
    visit(node)
    JS.is_leaf(node) || foreach(child -> walk(visit, child), JS.children(node))
    return nothing
end

end
