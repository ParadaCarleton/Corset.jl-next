"""
`temporary-array` (F32): method builds array only to reduce it once.

## Description
Reports broadcast (`f.(x)`) or collected (`collect`, `map`, comprehension) array of package method whose only uses are
shape reads and one `sure` read by reduction (`sum`, `prod`, `maximum`, `minimum`, `extrema`, `any`, `all`, `count`,
`reduce`, `foldl`, `foldr`, `mapreduce`). Allocations and their events come from `lifecycle` stage.
Fix passes function and source (`sum(f, x)`), generator, or iterator in place of array.

## Rationale
Reduction takes function and source, or generator: it computes each element when it needs it. Temporary array
allocates every element first, then frees them.

## Example
```julia
total_size(x::Vector{Float64}) = sum(abs.(x))
```

## Alternative
```julia
total_size(x::Vector{Float64}) = sum(abs, x)
```

## Limitations
Fix tier is `likely`: reduction over generator or function sums in order, so float result can differ in last bits from
pairwise sum of array. `foldr`, and keyword other than `init` (`dims`) on generator form, get `manual` fix: generator
cannot reverse or keep dimensions. Element calls interleave with reduction steps: element function and reduction operator that
share state, or both throw, can give other result or exception. Fix covers comprehension, `collect(it)`, and `f.(x)` as first argument of reduction that takes
function; other forms (`x .^ 2`, `map`) get `manual` fix. `any` and `all` get `manual` fix: they stop at first decisive
element, so lazy form skips later element calls and their effects. `reduce(vcat, A)` and `reduce(hcat, A)` are
exempt: Base concatenates array of arrays in one allocation, and lazy form concatenates pair by pair.
"""
module TemporaryArray

using ...Facts

const NAME = Symbol("temporary-array")

"""Base reductions that take generator in place of array."""
const REDUCTIONS = (:sum, :prod, :maximum, :minimum, :extrema, :any, :all, :count, :reduce, :foldl, :foldr, :mapreduce)

"""Reductions that stop at first decisive element: lazy form skips element calls after it."""
const SHORT_CIRCUITS = (:any, :all)

"""Reductions that also take function and source as first two arguments (`sum(f, x)`)."""
const MAPPING = (:sum, :prod, :maximum, :minimum, :extrema, :any, :all, :count)

"""Operators that `reduce` applies to array of arrays in one allocation (`reduce(vcat, A)`)."""
const CONCATENATIONS = (:vcat, :hcat)

"""Only reduction read of `array` when its other uses read shape only; `nothing` else."""
function single_reduction(array::ArrayLife)::Union{Nothing, ArrayEvent}
    array.kind in (AllocationKind.broadcast, AllocationKind.collected) || return nothing
    reads = ArrayEvent[]
    for event in array.events
        event.kind == ArrayEventKind.shape && continue
        event.kind == ArrayEventKind.read || return nothing
        push!(reads, event)
    end
    length(reads) == 1 || return nothing
    read = only(reads)
    (read.path == ArrayPath.sure && !read.view && read.callee in REDUCTIONS) || return nothing
    # Lazy form of `reduce(vcat, A)` concatenates pair by pair.
    (read.callee === :reduce && read.operator in CONCATENATIONS) && return nothing
    return read
end

"""Names of keyword arguments of syntax `call`; splatted keywords give their source text."""
function keyword_names(file::SyntaxFile, call::SyntaxNode)::Vector{String}
    names = String[]
    for argument in call_arguments(call)
        parts = kind_name(argument) == "parameters" ? children_of(argument) : kind_name(argument) in ("=", "kw") ? [argument] : SyntaxNode[]
        append!(names, [source(file, kind_name(part) in ("=", "kw") ? first(children_of(part)) : part) for part in parts])
    end
    return names
end

"""Whether `node` is only argument of `call`, without keyword arguments."""
only_argument(call::SyntaxNode, node::SyntaxNode)::Bool = (arguments = call_arguments(call); length(arguments) == 1 && only(arguments) === node)

"""
Replacement text for array `node` that reduction call takes as argument; `nothing` when no form fits. `mapping`: node
is first argument of reduction that also takes function and source, so `f.(x)` becomes `f, x`.
"""
function lazy_text(file::SyntaxFile, node::SyntaxNode, mapping::Bool)::Union{Nothing, String}
    kind = kind_name(node)
    # Generator outside sole-argument position needs its parentheses.
    parent = parent_of(node)
    sole = !isnothing(parent) && only_argument(something(parent), node)
    generator(inner::SyntaxNode)::String = sole ? source(file, inner) : "(" * source(file, inner) * ")"
    kind == "comprehension" && return generator(only(children_of(node)))
    if kind == "call" && call_head(node) == "collect" && length(call_arguments(node)) == 1
        inner = only(call_arguments(node))
        return kind_name(inner) == "generator" ? generator(inner) : source(file, inner)
    end
    # Prefix dotcall `f.(x)` only: infix `x .^ 2` has no function operand to pass.
    (mapping && kind == "dotcall" && callee_node(node) === first(children_of(node)) && length(call_arguments(node)) == 1) || return nothing
    return source(file, callee_node(node)) * ", " * source(file, only(call_arguments(node)))
end

"""Reduction call node of `read` and its file; `nothing` when span of `read` is no such node."""
function reduction_call(files::AbstractDict{String, SyntaxFile}, read::ArrayEvent)::Union{Nothing, Tuple{SyntaxFile, SyntaxNode}}
    file = get(files, read.span.file, nothing)
    isnothing(file) && return nothing
    calls = [node for node in forms(file, "call") if span(file, node) == read.span && call_head(node) == string(something(read.callee))]
    return isempty(calls) ? nothing : (file, first(calls))
end

"""
File and argument node of reduction `call` at operand position of `read`: array at `site`. Exact `site` must be that
node; line `site` (comprehension) needs node that can build array. `nothing` when no node fits.
"""
function array_target(file::SyntaxFile, call::SyntaxNode, read::ArrayEvent, site::Span)::Union{Nothing, Tuple{SyntaxFile, SyntaxNode}}
    isnothing(read.position) && return nothing
    # Keyword arguments can precede positional ones; operand position counts positional ones only.
    arguments = [argument for argument in call_arguments(call) if !(kind_name(argument) in ("=", "kw", "parameters"))]
    position = something(read.position)
    position <= length(arguments) || return nothing
    argument = arguments[position]
    site.precision == Precision.exact && return span(file, argument) == site ? (file, argument) : nothing
    return kind_name(argument) in ("comprehension", "call", "dotcall") ? (file, argument) : nothing
end

"""
Fix that passes generator, iterator, or function and source to reduction `read` in place of array argument `target`
(`array_target`). `manual` when array has no argument node, or node has no lazy form.
"""
function lazy_fix(target::Union{Nothing, Tuple{SyntaxFile, SyntaxNode}}, read::ArrayEvent)::Fix
    reduction = something(read.callee)
    # Array runs every element call; lazy `any` skips calls after first `true`, and their effects.
    reduction in SHORT_CIRCUITS && return manual_fix("pass function and source (`$reduction(f, x)`) when element function has no effects: `$reduction` stops at first decisive element")
    manual = manual_fix("pass function and source (`$reduction(f, x)`), or generator (`$reduction(f(v) for v in x)`)")
    isnothing(target) && return manual
    file, argument = something(target)
    # `foldr` reverses its source: generator over `Channel` cannot reverse.
    reduction === :foldr && return manual_fix("pass function and source to `mapfoldr` (`mapfoldr(f, op, x)`) when source can reverse")
    # Keyword `dims` needs array: only `f, x` form keeps array.
    keywords = keyword_names(file, something(parent_of(argument)))
    (kind_name(argument) == "dotcall" || all(==("init"), keywords)) || return manual
    text = lazy_text(file, argument, read.position == 1 && reduction in MAPPING)
    isnothing(text) && return manual
    return Fix("compute elements when `$reduction` needs them", [Edit(span(file, argument), something(text))], Tier.likely)
end

"""Findings for each temporary array of package method that one reduction consumes."""
function findings(facts::FactSet)::Vector{Finding}
    lifecycle = facts.lifecycle
    isnothing(lifecycle) && return Finding[]
    files, found = Dict(file.path => file for file in facts.files), Finding[]
    for method in lifecycle.methods, array in method.arrays
        read = single_reduction(array)
        isnothing(read) && continue
        reduction, call = something(read.callee), reduction_call(files, read)
        target = isnothing(call) ? nothing : array_target(something(call)..., read, array.site)
        # Argument node is exact even when allocation span is line only (comprehension).
        place = isnothing(target) ? array.site : span(something(target)...)
        push!(
            found, Finding(
                NAME, :temporary_array, Confidence.definite, "temporary array built only for one `$reduction`",
                Label(place, "allocates every element here"), [Label(read.span, "`$reduction` reads it once")],
                "`$reduction` can compute each element when it needs it, without array", lazy_fix(target, read),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.performance, [32], Stage.lifecycle, findings)

end
