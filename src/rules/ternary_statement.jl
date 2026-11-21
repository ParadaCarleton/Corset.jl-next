"""
`ternary-statement` (F113): ternary runs code as statement; value it picks is dropped.

## Description
Reports `?:` whose value goes unused: statement in block or loop body, or branch of construct whose value goes unused.
Ternary in branch of other ternary belongs to outer one.

## Rationale
Julia manual: `?:` picks between values; `if` runs code. Reader of ternary looks for use of picked value.

## Example
```julia
for x in xs
    x > 0 ? push!(positive, x) : nothing
end
```

## Alternative
```julia
for x in xs
    if x > 0
        push!(positive, x)
    end
end
```

## Limitations
Ternary that gives value of function, closure or block passes, since caller may use value.
Fix drops literal branch and turns ternary in `else` branch into `elseif`.
Fix is manual when statement shares line with other code, holds comment, or has literal in both branches.
"""
module TernaryStatement

using ...Facts

const NAME = Symbol("ternary-statement")

"""Whether `node` is branch of ternary around it, so outer ternary stands for it."""
function branch(node::SyntaxNode)::Bool
    parent = parent_of(node)
    return !isnothing(parent) && kind_name(parent) == "?" && children_of(parent)[1] !== node
end

"""Whether ternary `node` and each ternary in its branches keep one branch that is not literal."""
function rewritable(node::SyntaxNode)::Bool
    _, yes, no = children_of(node)
    literal(yes) && literal(no) && return false
    return all(part -> kind_name(part) != "?" || rewritable(part), (yes, no))
end

"""Body text of branch `node` at `indent`: ternary becomes nested `if`; parentheses drop; block gives one line per statement."""
body(file::SyntaxFile, node::SyntaxNode, indent::String)::String =
    kind_name(node) == "?" ? if_text(branches(file, node, indent), indent) : body_text(file, node, indent)

"""Branches of ternary `node` at `indent`: literal branch drops; ternary in `else` branch joins as `elseif`."""
function branches(file::SyntaxFile, node::SyntaxNode, indent::String)::Vector{Branch}
    condition, yes, no = children_of(node)
    inner = indent * "    "
    literal(yes) && return [negated(file, condition, CONDITION) => body(file, no, inner)]
    found = Branch[operand(file, condition, CONDITION) => body(file, yes, inner)]
    literal(no) && return found
    kind_name(no) == "?" && return append!(found, branches(file, no, indent))
    return push!(found, nothing => body(file, no, inner))
end

"""Fix for statement ternary `node`: `safe` rewrite as `if`, or manual when statement shares lines, holds comment or keeps no code."""
function rewrite_fix(file::SyntaxFile, node::SyntaxNode)::Fix
    indent = statement_indent(file, node)
    (isnothing(indent) || !rewritable(node)) && return manual_fix("rewrite as `if` statement")
    return Fix("rewrite as `if` statement", [Edit(span(file, node), if_text(branches(file, node, indent), indent))], Tier.safe)
end

"""Findings for ternaries whose value goes unused."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, node in forms(file, "?")
        discarded(node) && !branch(node) || continue
        push!(
            found, finding(
                NAME, file, node; kind = :dropped_value, confidence = Confidence.definite,
                message = "ternary runs code as statement", label = "picked value dropped",
                why = "`?:` picks between values and `if` runs code; reader looks for use of value that never comes",
                fix = rewrite_fix(file, node),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [113], Stage.syntax, findings)

end
