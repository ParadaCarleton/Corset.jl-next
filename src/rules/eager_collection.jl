# The `collect` and `dims-keyword` rules: lazy iterators and slices over eager `Vector`s and `dims` reductions.

"""Calls of `collect`, which always builds a `Vector` and drops the array type of its input, keyed by file and the function they sit in."""
function collect_calls(source::Source)::Vector{Site}
    (; path, name, located) = source
    return [
        Site("$name $(item.enclosing)", path, item.line, "`collect` builds a `Vector`; keep the iterator, or use `similar` and `copyto!`/`copy`")
            for item in located if callee(item.node) === :collect
    ]
end

"""Calls and broadcasts that pass a `dims` keyword (`sum(x; dims = 1)`), keyed by file and the function they sit in."""
function dims_keyword_calls(source::Source)::Vector{Site}
    (; path, name, located) = source
    return [
        Site("$name $(item.enclosing)", path, item.line, "`dims` reduces by position; slice with `eachslice`, `eachrow` or `eachcol` and reduce each slice")
            for item in located if callee(item.node) !== NO_NAME && has_dims_keyword(item.node)
    ]
end

"""Whether call or broadcast `node` has a `dims` keyword argument: `dims = …` inline or after `;`, or the shorthand `; dims`."""
has_dims_keyword(node::Expr)::Bool = any(is_dims_argument, is_broadcast(node) ? (last(node.args)::Expr).args : node.args)

"""Whether argument `argument` of a call is `dims = …`, or a block of keywords after `;` with one of them."""
is_dims_argument(argument::Expr)::Bool = argument.head === :parameters ? any(is_dims_keyword, argument.args) : is_dims_keyword(argument)
is_dims_argument(::Any)::Bool = false

"""Whether `keyword`, an entry after `;`, is `dims = …` or `dims` alone."""
is_dims_keyword(keyword::Expr)::Bool = keyword.head === :kw && first(keyword.args) === :dims
is_dims_keyword(keyword::Symbol)::Bool = keyword === :dims
