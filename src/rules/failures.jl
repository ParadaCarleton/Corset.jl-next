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
mentions_finiteness(node::Expr)::Bool = any(mentions_any_finiteness, node.args)
mentions_finiteness(node::Symbol)::Bool = node in FINITENESS_TESTS

"""Whether parsed `node`, of any kind, mentions a finiteness test; inlined so the check of its kind leaves calls on concrete types."""
@inline function mentions_any_finiteness(node::Any)::Bool
    if node isa Expr
        return mentions_finiteness(node)
    elseif node isa Symbol
        return mentions_finiteness(node)
    end
    return false
end

"""Whether the expression `item` drops or skips elements by a finiteness test: `filter(isfinite, x)`, `x[isfinite.(x)]` or `isnan(x) && continue`."""
function drops_nonfinite(node::Expr)::Bool
    if node.head === :call && callee(node) in ELEMENT_FILTERS
        return any(mentions_any_finiteness, call_arguments(node))
    end
    if node.head === :ref
        return any(mentions_any_finiteness, node.args[2:end])
    end
    if node.head === :if
        return mentions_any_finiteness(first(node.args)) && any(branch -> Meta.isexpr(branch, :block) && any(Base.Fix2(Meta.isexpr, :continue), branch.args), node.args[2:end])
    end
    return node.head === :(&&) && mentions_any_finiteness(first(node.args)) && Meta.isexpr(last(node.args), :continue)
end

"""Elements dropped or skipped by a finiteness test, keyed by file and the function they sit in; a NaN or infinity is a failure to report."""
function nonfinite_drops(source::Source)::Vector{Site}
    (; path, name, located) = source
    return [
        Site("$name $(item.enclosing)", path, item.line, "drops NaN or infinity; return the failure to the caller")
            for item in located if drops_nonfinite(item.node)
    ]
end
