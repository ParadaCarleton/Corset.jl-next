"""
`stateful-reuse` (F51): method starts iterator twice, or lets it escape after start, where its type admits stateful iterator.

## Description
Reports second start of one iterator on one path, and iterator that escapes after start or starts after escape.
Start: `iterate` without state, `for` loop, destructuring, `first`, `only`, generic `isempty`, consuming call
(`collect`, `sum`, `map`, …), or `zip` operand. Escape: return, store, operand `!` call does not write, or operand of
package function. Start inside loop restarts on each pass, unless loop makes new object each pass. Rule checks type
that can hold stateful and multi-pass iterators both: abstract type other than `AbstractArray`, `AbstractDict`,
`AbstractSet`, `AbstractString`, `Tuple`, `NamedTuple`, `Number` or `AbstractChar`, or union of both kinds. One object
and definite starts give `definite`; overlapping objects, or `isempty` that other methods can serve, give `possible`.

## Rationale
Generic code that restarts its argument works on vector and loses elements on stateful iterator such as
`Iterators.Stateful` or `eachline` result: `first` consumes first element, so loop after it starts at second element.
Iterator that escapes after start hands consumed state to other code. Tests with arrays do not show this.

## Example
```julia
function total(itr::Any)
    isempty(itr) && return 0
    s = 0
    for x in itr
        s += x
    end
    return s
end
```

## Alternative
```julia
function total(itr::Any)
    peeled = Iterators.peel(itr)
    isnothing(peeled) && return 0
    first, rest = peeled
    s = first
    for x in rest
        s += x
    end
    return s
end
```

## Limitations
Lazy wrapper (`enumerate(itr)`, `Iterators.take(itr, n)`) starts nothing until code iterates it; rule sees no start
there. `zip` with used result counts at its call. Concrete type and known stateful type pass: code that restarts `eachline` result
consumes lines on purpose. Rule sees methods inference reaches, as `never-succeeds` does. Fix is `manual`.
"""
module StatefulReuse

using ...Facts

const NAME = Symbol("stateful-reuse")

"""Message, primary label and cause label (`nothing`: none) of `reuse`."""
function wording(reuse::Facts.StatefulReuse)::Tuple{String, String, Union{Nothing, String}}
    iterator = isnothing(reuse.iterator) ? "iterator" : "`$(reuse.iterator)`"
    if !reuse.earlier_escapes && !reuse.later_escapes
        reuse.repeats && return ("$iterator starts again on each loop pass", "starts iteration inside loop", nothing)
        reuse.earlier == reuse.later && return ("$iterator starts iteration twice in one expression", "starts iteration twice", nothing)
        return ("$iterator starts iteration twice", "starts iteration again", "first start")
    end
    reuse.later_escapes && return ("$iterator escapes after iteration started", "lets iterator escape", "starts iteration")
    return ("$iterator starts iteration after it escaped", "starts iteration", "lets iterator escape")
end

"""Findings for each iterator that method starts twice or lets escape after start."""
function findings(facts::FactSet)::Vector{Finding}
    effects = facts.effects
    isnothing(effects) && return Finding[]
    found = Finding[]
    for method in effects.methods, reuse in method.stateful_reuses
        message, label, cause = wording(reuse)
        causes = isnothing(cause) ? Label[] : [Label(reuse.earlier, cause)]
        kind = reuse.earlier_escapes || reuse.later_escapes ? :escape : :restart
        push!(
            found, Finding(
                NAME, kind, reuse.confidence, message, Label(reuse.later, label), causes,
                "stateful iterator gives each element once, so second pass misses elements first pass consumed",
                manual_fix("take first element with `Iterators.peel`, thread `iterate` state, or narrow argument to multi-pass type"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [51], Stage.effects, findings)

end
