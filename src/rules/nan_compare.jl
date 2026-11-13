"""
`nan-compare` (F95): comparison with `NaN` has fixed result.

## Description
Reports equality, order and identity comparisons with `NaN`, `NaN16`, `NaN32` or `NaN64`.
Covers dotted operators (`x .== NaN`), chained comparisons, and curried operators (`==(NaN)`).

## Rationale
NaN equals no value, itself included. `x == NaN` and `x < NaN` are never true, and `x != NaN` is never false.
NaN also has many bit patterns, so `x === NaN` misses NaN from arithmetic: `0/0 === NaN` is false.

## Example
```julia
valid = filter(x -> x != NaN, samples)
```

## Alternative
```julia
valid = filter(!isnan, samples)
```

## Limitations
Rule sees NaN constants only. NaN held in variable or built by call (`T(NaN)`) passes.
Fix for `==` and `!=` writes `isnan` with tier `likely`: `isnan` throws for values that are not numbers.
"""
module NanCompare

using ...Facts

const NAME = Symbol("nan-compare")
"""NaN constants; `Base.NaN32` also matches."""
const NANS = ("NaN", "NaN16", "NaN32", "NaN64")
"""Finding kind of each operator: equality has mechanical fix, order and identity need manual fix."""
const KINDS = Dict(
    "==" => :equality, "!=" => :equality, "≠" => :equality,
    "<" => :order, "<=" => :order, "≤" => :order, ">" => :order, ">=" => :order, "≥" => :order,
    "===" => :identity, "!==" => :identity, "≡" => :identity, "≢" => :identity,
)
"""Operators true where their plain form is false."""
const NEGATED = ("!=", "≠", "!==", "≢")
const LABELS = Dict(:equality => "NaN equals no value, itself included", :order => "NaN has no order", :identity => "compares bits")
const WHY = Dict(
    :equality => "IEEE comparison with NaN is false, and `!=` is true",
    :order => "IEEE order comparison with NaN is false",
    :identity => "NaN has many bit patterns; `0/0 === NaN` is false",
)

"""One comparison: node to report, operator as written (`".=="`), operands (one for curried `==(NaN)`), chain flag."""
const Link = @NamedTuple{node::SyntaxNode, operator::String, operands::Vector{SyntaxNode}, chained::Bool}

"""Operator of chain link `node` as written: `"<"`, or `".<"` for dotted link."""
chain_operator(node::SyntaxNode)::String = kind_name(node) == "." ? "." * chain_operator(children_of(node)[1]) : something(identifier_name(node), "")

"""Operator without broadcast dot: `"=="` for `".=="`."""
plain(operator::String)::String = chopprefix(operator, ".")

"""Whether `node` names NaN constant."""
is_nan(node::SyntaxNode)::Bool = base_name(node) in NANS

"""Comparisons with NaN constant in `file`: infix, dotted, prefix and curried operator calls, and first such link of each chain."""
function nan_links(file::SyntaxFile)::Vector{Link}
    found = Link[]
    for node in [forms(file, "call"); forms(file, "dotcall")]
        infix, parts = infix_operator(node), children_of(node)
        operator = something(infix, call_head(node), "")
        haskey(KINDS, plain(operator)) || continue
        operands = isnothing(infix) ? collect(parts[2:end]) : [parts[1], parts[3]]
        isnothing(infix) && (length(operands) > 2 || any(part -> kind_name(part) == "parameters", operands)) && continue
        any(is_nan, operands) && push!(found, (; node, operator, operands, chained = false))
    end
    for node in forms(file, "comparison")
        parts = children_of(node)
        for index in 2:2:(length(parts) - 1)
            operator, operands = chain_operator(parts[index]), [parts[index - 1], parts[index + 1]]
            haskey(KINDS, plain(operator)) && any(is_nan, operands) || continue
            push!(found, (; node, operator, operands, chained = true))
            break
        end
    end
    return found
end

"""Operand compared with NaN: first operand that is not NaN, else first; `nothing` for curried operator."""
compared(link::Link)::Union{Nothing, SyntaxNode} =
    length(link.operands) == 1 ? nothing : link.operands[is_nan(link.operands[1]) && !is_nan(link.operands[2]) ? 2 : 1]

"""Fix for comparison `link`: `isnan` replaces `==` and `!=` outside chains; manual otherwise."""
function nan_fix(file::SyntaxFile, link::Link)::Fix
    kind, negated, dotted = KINDS[plain(link.operator)], plain(link.operator) in NEGATED, startswith(link.operator, ".")
    other = compared(link)
    # Assignment inside call parentheses reads as keyword argument, even when grouped.
    !isnothing(other) && kind_name(other) == "=" && return manual_fix("assign before comparison, then test value with `isnan`")
    test = isnothing(other) ? "isnan" : (dotted ? "isnan.(" : "isnan(") * source(file, other) * ")"
    kind == :equality && !link.chained || return manual_fix("test for NaN with `$test`$(kind == :identity ? ", which matches every bit pattern" : "")")
    return replace_fix(file, link.node, (negated ? (dotted ? ".!" : "!") : "") * test, Tier.likely)
end

"""Findings for comparisons with NaN constant, one per node."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, link in nan_links(file)
        kind, negated = KINDS[plain(link.operator)], plain(link.operator) in NEGATED
        text = link.chained ? join([source(file, link.operands[1]), link.operator, source(file, link.operands[2])], " ") : source(file, link.node)
        push!(
            found, finding(
                NAME, file, link.node; kind, confidence = Confidence.definite,
                message = kind == :identity ? "`$text` is $negated for NaN with other bit patterns" : "`$text` is never $(!negated)",
                label = LABELS[kind], why = WHY[kind], fix = nan_fix(file, link),
            )
        )
    end
    return sort!(found; by = finding -> finding.primary.span.first_byte)
end

const ENTRY = RuleEntry(NAME, Group.correctness, [95], Stage.syntax, findings)

end
