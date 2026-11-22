"""
`stateful-iterate` (F109): `iterate` on `Iterators.Stateful`.

## Description
Reports call `iterate(s)` or `iterate(s, state)` where inference types `s` as `Iterators.Stateful`. `for` loops are
exempt: they consume iterator by design.

## Rationale
`iterate` on `Stateful` removes element from iterator, but name has no `!`. Reader takes call for read, and second
call returns next element. `popfirst!` names write.

## Example
```julia
function head(s::Iterators.Stateful)
    x, _ = iterate(s)
    return x
end
```

## Alternative
```julia
head(s::Iterators.Stateful) = popfirst!(s)
```

## Limitations
Fix is `manual`: `popfirst!` returns element without state, and throws `EOFError` where `iterate` returns
`nothing`. Rewrite destructuring and guard with `isempty(s)` first.
Rule sees methods inference reaches, as `never-succeeds` does.
"""
module StatefulIterate

using ...Facts

const NAME = Symbol("stateful-iterate")

"""Findings for each `iterate` call on `Iterators.Stateful`."""
function findings(facts::FactSet)::Vector{Finding}
    inference = facts.inference
    isnothing(inference) && return Finding[]
    return [
        Finding(
            NAME, :stateful_iterate, Confidence.definite, "`iterate` on `Iterators.Stateful` hides write to `$(call.iterator)`",
            Label(call.span, "removes element from `$(call.iterator)`"), Label[],
            "name without `!` reads as query, but each call consumes element",
            manual_fix("use `popfirst!($(call.iterator))`: it returns element without state, and throws `EOFError` where `iterate` returns `nothing`; check `isempty($(call.iterator))` first"),
        ) for call in inference.stateful_iterates
    ]
end

const ENTRY = RuleEntry(NAME, Group.readability, [109], Stage.inference, findings)

end
