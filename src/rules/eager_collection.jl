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
function has_dims_keyword(node::Expr)::Bool
    arguments = is_broadcast(node) ? last(node.args).args : node.args
    keywords = Any[argument for argument in arguments if Meta.isexpr(argument, :kw)]
    for argument in arguments
        if Meta.isexpr(argument, :parameters)
            append!(keywords, argument.args)
        end
    end
    return any(keyword -> keyword === :dims || (Meta.isexpr(keyword, :kw) && first(keyword.args) === :dims), keywords)
end
