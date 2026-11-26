# Facts of `package` stage (`architecture.md`): sites of package methods and structs, and argument uses.

"""
Method package code defines, in analyzed `file`. `node` is its definition node, when exactly one definition of that
name starts on method line; `nothing` otherwise (`@eval` loops, macro output), and `span` then has line precision.
"""
struct MethodSite
    method::Method
    file::SyntaxFile
    node::Union{Nothing, SyntaxNode}
    span::Span
end

"""Struct package code defines, as written (`UnionAll` for parametric struct), and its `struct` form in analyzed `file`."""
struct StructSite
    type::Type
    file::SyntaxFile
    node::SyntaxNode
end

"""
Use of package method argument that needs declared container type (`package` stage fact): body stores argument into
struct field of type in `stored`. Use is direct, through closure that captures argument, or through argument of package
callee. Blind spot: open callee, splat, vararg and keyword value; element of argument; argument that value holds (tuple,
named tuple, array, `Pair`, `Ref`); function argument that other call runs.
"""
struct ArgumentUse
    stored::Vector{Any}
end

"""`!` functions that change size or key set of collection (Base docstrings): loop over it can skip or repeat elements (F48)."""
const RESIZE_FUNCTIONS = Base.IdSet{Any}(
    Any[
        push!, pushfirst!, pop!, popfirst!, popat!, insert!, deleteat!, delete!, empty!, append!, prepend!, resize!,
        splice!, filter!, keepat!, unique!, merge!, mergewith!, union!, intersect!, setdiff!, symdiff!,
    ],
)

"""
Loaded package (`package` stage facts): package modules (root, submodules, loaded extensions; root first), values
public names reach, and sites of methods and structs package modules define in analyzed files.
`methods` keeps methods later definitions replaced; `overwrites` pairs each (earlier, later) by same signature.
`probed`: functions, types and callable objects package methods test for methods; new method changes what code does.
`uses`: arguments of package methods, by position, whose uses need declared container type (`ArgumentUse`).
`keyword_bodies`: keyword body (`#f#1`) of each method in `methods` with keywords, at site of its definition. Code of
method with keywords runs there; `methods` keeps wrapper that fills defaults.
"""
struct PackageFacts
    modules::Vector{Module}
    public::Base.IdSet{Any}
    methods::Vector{MethodSite}
    keyword_bodies::Vector{MethodSite}
    overwrites::Vector{Tuple{MethodSite, MethodSite}}
    structs::Vector{StructSite}
    probed::Base.IdSet{Any}
    uses::IdDict{Method, Dict{Int, ArgumentUse}}
end
