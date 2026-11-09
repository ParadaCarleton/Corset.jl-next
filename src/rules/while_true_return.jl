# The `while-true-return` rule: a loop ends on its condition, and the function returns after it.

"""
`while true` loops with a `return` inside, keyed by file and the function they sit in. A `return` in a
nested function or anonymous function leaves that function, so it passes.
"""
function while_true_returns(source::Source)::Vector{Site}
    (; path, name, located) = source
    return [
        Site("$name $(item.enclosing)", path, item.line, "loops forever and leaves by `return`; end it on its condition and return after it")
            for item in located if item.node.head === :while && first(item.node.args) === true && returns_here(item.node.args[2])
    ]
end

"""Whether parsed expression `node` holds a `return` that leaves the function around it, not one inside a nested function."""
returns_here(node::Expr)::Bool = node.head === :return || (node.head ∉ (:function, :->) && any(returns_here, node.args))
returns_here(::Any)::Bool = false
