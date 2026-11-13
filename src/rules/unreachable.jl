"""
`unreachable` (F96): code never runs.

## Description
Reports `elseif` condition equal to earlier condition of same `if` chain, when conditions have no side effects.
Reports first statement after `return`, `break`, `continue`, `throw`, `rethrow` or `error` in same block.

## Rationale
Earlier branch takes every case where repeated condition holds, so later branch is dead.
Statement after exit never runs: usually code left from debugging, or exit put too early.

## Example
```julia
if x > 0
    grow(x)
elseif x > 0
    shrink(x)
end
```

## Alternative
```julia
if x > 0
    grow(x)
elseif x < 0
    shrink(x)
end
```

## Limitations
Conditions compare as source text with whitespace collapsed: `a+b` and `a + b` differ.
Condition counts as free of side effects only with names, literals, field access, indexing, operators and few pure Base predicates.
Rule sees exit statements only: code after `if` whose branches all return passes.
Block with `@label` after exit passes, since `@goto` can reach it.
"""
module Unreachable

using ...Facts

const NAME = :unreachable
"""Operators and Base functions that read arguments without side effects."""
const PURE_CALLS = Set(
    [
        "==", "!=", "≠", "===", "!==", "≡", "≢", "<", "<=", "≤", ">", ">=", "≥", "!", "+", "-", "*", "/", "÷", "%", "^", "\\",
        "&", "|", "⊻", "<<", ">>", ">>>", "isa", "in", "∈", "∉", "isnothing", "ismissing", "isempty", "iszero", "isone",
        "isnan", "isinf", "isfinite", "iseven", "isodd", "haskey", "length", "keys", "typeof",
    ]
)
"""Forms free of side effects when their children are."""
const PURE_FORMS = ("comparison", "&&", "||", ".", "ref", "string", "char", "quote", "tuple", "vect", "curly", "<:", ">:")
"""Statements that leave block."""
const JUMPS = ("return", "break", "continue")
"""Calls that throw, so leave every block."""
const THROWS = ("throw", "rethrow", "error")

"""Whether evaluating `node` has no side effects: leaf, or pure form or call of pure children."""
function pure(node::SyntaxNode)::Bool
    isnothing(leaf_value(node)) || return true
    kind = kind_name(node)
    (kind == "call" ? call_head(node) in PURE_CALLS : kind in PURE_FORMS) || return false
    return all(pure, children_of(node))
end

"""Conditions of `if` chain at `node`: `if` condition, then each `elseif` condition."""
function chain_conditions(node::SyntaxNode)::Vector{SyntaxNode}
    links = [node]
    while length(children_of(links[end])) == 3 && kind_name(children_of(links[end])[3]) == "elseif"
        push!(links, children_of(links[end])[3])
    end
    return [children_of(link)[1] for link in links]
end

"""Findings for conditions equal to earlier condition of same chain, with only pure conditions from earlier one on."""
function repeated_conditions(file::SyntaxFile, node::SyntaxNode)::Vector{Finding}
    found, seen = Finding[], Dict{String, SyntaxNode}()
    for condition in chain_conditions(node)
        # Impure condition may change state that later conditions read.
        pure(condition) || (empty!(seen); continue)
        text = normalized_source(file, condition)
        earlier = get!(seen, text, condition)
        earlier === condition && continue
        push!(
            found, finding(
                NAME, file, condition; kind = :repeated_condition, confidence = Confidence.definite,
                message = "condition repeats earlier condition of same `if` chain", label = "branch never runs",
                why = "earlier branch takes every case where condition holds; condition has no side effects to change that",
                fix = manual_fix("change condition to intended one, or delete branch"),
                causes = [Label(span(file, earlier), "same condition")],
            )
        )
    end
    return found
end

"""
Exit that `statement` makes in `block`, or `nothing`. Top-level code and module body run each statement apart,
so only throwing calls leave them.
"""
function exit_name(block::SyntaxNode, statement::SyntaxNode)::Union{Nothing, String}
    apart = kind_name(block) == "toplevel" || kind_name(parent_of(block)) == "module"
    kind_name(statement) in JUMPS && return apart ? nothing : kind_name(statement)
    head = call_head(statement)
    return head in THROWS ? head : nothing
end

"""
Finding for first statement after exit in `block`; `nothing` when none, or when `@label` follows exit.
`labels` holds sorted first bytes of `@label` calls.
"""
function after_exit(file::SyntaxFile, block::SyntaxNode, labels::Vector{Int})::Union{Nothing, Finding}
    statements = children_of(block)
    index = findfirst(statement -> !isnothing(exit_name(block, statement)), statements)
    (isnothing(index) || index == length(statements)) && return nothing
    exit, dead = statements[index], statements[index + 1]
    next_label = searchsortedfirst(labels, span(file, exit).last_byte)
    next_label <= length(labels) && labels[next_label] <= span(file, statements[end]).last_byte && return nothing
    name = exit_name(block, exit)
    return finding(
        NAME, file, dead; kind = :after_exit, confidence = Confidence.definite,
        message = "statement after `$name` never runs", label = "unreachable statement",
        why = "control leaves block at `$name`; code below it in same block never runs",
        fix = manual_fix("delete unreachable code, or delete exit left from debugging"),
        causes = [Label(span(file, exit), "block exits here")],
    )
end

"""Findings for repeated pure `if` chain conditions and statements after exit."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        foreach(node -> append!(found, repeated_conditions(file, node)), forms(file, "if"))
        labels = sort!([span(file, call).first_byte for call in forms(file, "macrocall") if leaf_value(children_of(call)[1]) == "@label"])
        for block in [forms(file, "block"); forms(file, "toplevel")]
            dead_code = after_exit(file, block, labels)
            isnothing(dead_code) || push!(found, dead_code)
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [96], Stage.syntax, run)

end
