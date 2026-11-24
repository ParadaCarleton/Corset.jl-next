"""
`impure-lambda` (F56): anonymous function writes state inside call of Base query function.

## Description
Reports call of Base function without `!` that calls function argument (`map`, `filter`, `sum`, `sort` with `by`)
when its anonymous function writes state: captured variable, method argument, or global.
Function that writes only objects it creates passes. `foreach`, functions with `!` and ordered folds (`foldl`) pass.
Named function passes: name with `!` states write (`bang-convention`).

## Rationale
Query function promises result only: order and number of calls to its function are Base detail.
Write then depends on Base internals, and call that reads as query changes state.

## Example
```julia
function first_seen(items::Vector{Int})
    seen = Set{Int}()
    return filter(item -> item in seen ? false : (push!(seen, item); true), items)
end
```

## Alternative
```julia
function first_seen(items::Vector{Int})
    seen, kept = Set{Int}(), Int[]
    for item in items
        item in seen || (push!(seen, item); push!(kept, item))
    end
    return kept
end
```

## Limitations
Call facts merge writes of closures call invokes: named callable argument that writes gives finding too.
Write through local assigned twice, or call with stand-in operand, gives `possible` finding.
"""
module ImpureLambda

using ...Facts

const NAME = Symbol("impure-lambda")

"""
Base functions without `!` that call function argument and promise result only: order and number of calls stay Base
detail. `foreach` and ordered folds (`foldl`, `accumulate`) stay out.
"""
const QUERIES = Set(
    [
        "map", "filter", "count", "any", "all", "sum", "prod", "maximum", "minimum", "extrema", "mapreduce", "reduce",
        "findfirst", "findlast", "findall", "findmax", "findmin", "argmax", "argmin", "sort", "sortperm", "partialsort",
        "partialsortperm", "unique", "allunique", "issorted",
    ]
)

"""Whether `node` is anonymous function: `x -> body`, `do` block, or `function (x) body end`."""
function anonymous(node::SyntaxNode)::Bool
    kind = kind_name(node)
    return kind in ("->", "do") || (kind == "function" && kind_name(children_of(node)[1]) in ("tuple", "tuple-p"))
end

"""Anonymous function arguments of call `node`, keyword values (`by = item -> -item`) and `do` block included."""
function lambdas(node::SyntaxNode)::Vector{SyntaxNode}
    found = SyntaxNode[]
    for argument in call_arguments(node), part in (kind_name(argument) == "parameters" ? children_of(argument) : [argument])
        value = kind_name(part) in ("=", "kw") ? last(children_of(part)) : part
        anonymous(value) && push!(found, value)
    end
    return found
end

"""Call nodes of `files` with their file, by path and byte range."""
function calls(files::AbstractVector{SyntaxFile})::Dict{Tuple{String, Int, Int}, Tuple{SyntaxFile, SyntaxNode}}
    found = Dict{Tuple{String, Int, Int}, Tuple{SyntaxFile, SyntaxNode}}()
    for file in files, node in forms(file, "call")
        bounds = span(file, node)
        found[(file.path, bounds.first_byte, bounds.last_byte)] = (file, node)
    end
    return found
end

"""Name of Base query function (`QUERIES`) that every method of `call` belongs to; `nothing` for other callee."""
function query_name(call::CallFact)::Union{Nothing, String}
    name, methods = callee_name(call.callee), callee_methods(call.callee)
    (isnothing(name) || isnothing(methods) || isempty(methods)) && return nothing
    return name in QUERIES && all(method -> Base.moduleroot(method.module) === Base, methods) ? name : nothing
end

"""Findings for each call of Base query function whose anonymous function argument writes state; certain write first."""
function findings(facts::FactSet)::Vector{Finding}
    effects = facts.effects
    isnothing(effects) && return Finding[]
    found, sources = Finding[], calls(facts.files)
    for method in effects.methods, call in method.calls
        EffectKind.memory in call.closure_kinds && call.span.precision == Precision.exact || continue
        name = query_name(call)
        site = get(sources, (call.span.file, call.span.first_byte, call.span.last_byte), nothing)
        (isnothing(name) || isnothing(site)) && continue
        file, node = site
        last(split(source(file, callee_node(node)), '.')) == name || continue
        functions = lambdas(node)
        isempty(functions) && continue
        sure = EffectKind.memory in call.closure_definite && !call.stand_in
        push!(
            found, Finding(
                NAME, :write, sure ? Confidence.definite : Confidence.possible, "anonymous function passed to `$name` writes state",
                Label(call.span, "`$name` chooses order and number of calls"), [Label(span(file, lambda), "writes state") for lambda in functions],
                "write depends on Base internals, and call that reads as query changes state", manual_fix("write loop, or use `foreach`"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [56], Stage.effects, findings)

end
