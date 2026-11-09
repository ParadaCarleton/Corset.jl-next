# The `throw-call` and `nonfinite-drop` rules: a failure is a value the caller reads, never an exception or a skipped element.

"""The calls that raise an exception."""
const RAISERS = (:throw, :error)

"""Calls of `throw` and `error`, keyed by file and the function they sit in; an `ArgumentError` for a caller's bad input is one a project may waive."""
function raise_calls(source::Source)::Vector{Site}
    (; path, name, located) = source
    return [
        Site("$name $(item.enclosing)", path, item.line, "raises; return the failure as a typed value")
            for item in located if item.node.head === :call && callee(item.node) in RAISERS
    ]
end

"""The tests of a number's finiteness."""
const FINITENESS_TESTS = (:isfinite, :isnan, :isinf)

"""The calls that keep or drop elements by a predicate."""
const ELEMENT_FILTERS = (:filter, :filter!, :findall, :deleteat!, :count)

"""Whether parsed expression `node` mentions a finiteness test at any depth."""
mentions_finiteness(node::Expr)::Bool = any(mentions_finiteness, node.args)
mentions_finiteness(node::Symbol)::Bool = node in FINITENESS_TESTS
mentions_finiteness(::Any)::Bool = false

"""Whether the expression `item` drops or skips elements by a finiteness test: `filter(isfinite, x)`, `x[isfinite.(x)]` or `isnan(x) && continue`."""
function drops_nonfinite(node::Expr)::Bool
    if node.head === :call && callee(node) in ELEMENT_FILTERS
        return any(mentions_finiteness, call_arguments(node))
    end
    if node.head === :ref
        return any(mentions_finiteness, node.args[2:end])
    end
    if node.head === :if
        return mentions_finiteness(first(node.args)) && any(branch -> Meta.isexpr(branch, :block) && any(statement -> statement == Expr(:continue), branch.args), node.args[2:end])
    end
    return node.head === :(&&) && mentions_finiteness(first(node.args)) && last(node.args) == Expr(:continue)
end

"""Elements dropped or skipped by a finiteness test, keyed by file and the function they sit in; a NaN or infinity is a failure to report."""
function nonfinite_drops(source::Source)::Vector{Site}
    (; path, name, located) = source
    return [
        Site("$name $(item.enclosing)", path, item.line, "drops NaN or infinity; return the failure to the caller")
            for item in located if drops_nonfinite(item.node)
    ]
end
