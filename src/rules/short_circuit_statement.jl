"""
`short-circuit-statement` (F115): `&&` or `||` runs code as statement.

## Description
Reports `&&` or `||` chain whose value goes unused, so chain only picks whether its last term runs.
Restriction rule: no project kind turns it on. Set its level to `warn` to use it.

## Rationale
`if` shows at first glance that code runs on condition; chain reads as `Bool` expression.
Julia manual endorses chain for short `if`, so rule is project taste. Clippy `short_circuit_statement` does same.

## Example
```julia
n >= 0 || error("n must be non-negative")
```

## Alternative
```julia
if !(n >= 0)
    error("n must be non-negative")
end
```

## Limitations
Chain in condition, assignment, argument or function result passes.
Fix keeps comparison and adds `!`: `!(a >= b)` differs from `a < b` when value is `NaN`.
`&&` term of `||` chain turns into `||` of negated terms, so `if` branches on each test and keeps type narrowing.
Fix is manual when statement shares line with other code or holds comment.
"""
module ShortCircuitStatement

using ...Facts

const NAME = Symbol("short-circuit-statement")

"""Branch of chain `node` at `indent`: `&&` runs last term when others hold, `||` when none holds; chain tail nests."""
function branches(file::SyntaxFile, node::SyntaxNode, indent::String)::Vector{Branch}
    parts = terms(node)
    head, tail = parts[1:(end - 1)], parts[end]
    all_hold = length(head) == 1 ? operand(file, only(head), CONDITION) : join((operand(file, part, :&&) for part in head), " && ")
    condition = kind_name(node) == "&&" ? all_hold : none_text(file, head)
    inner = indent * "    "
    body = kind_name(tail) in ("&&", "||") ? if_text(branches(file, tail, inner), inner) : body_text(file, tail, inner)
    return [condition => body]
end

"""Fix for statement chain `node`: `safe` rewrite as `if`, or manual when statement shares lines or holds comment."""
function rewrite_fix(file::SyntaxFile, node::SyntaxNode)::Fix
    indent = statement_indent(file, node)
    isnothing(indent) && return manual_fix("rewrite as `if` statement")
    return Fix("rewrite as `if` statement", [Edit(span(file, node), if_text(branches(file, node, indent), indent))], Tier.safe)
end

"""Findings for `&&` and `||` chains whose value goes unused."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, operator in ("&&", "||"), node in forms(file, operator)
        discarded(node) && !later_term(node) || continue
        push!(
            found, finding(
                NAME, file, node; kind = :chain_statement, confidence = Confidence.definite,
                message = "`$operator` chain runs code as statement", label = "hides `if`",
                why = "project prefers `if` for code that runs on condition; chain reads as `Bool` expression",
                fix = rewrite_fix(file, node),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.restriction, [115], Stage.syntax, findings)

end
