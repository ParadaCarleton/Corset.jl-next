"""
`broadcast-rebind` (F41): loop replaces buffer with new broadcast array each iteration.

## Description
Reports broadcast (`x = f.(x)`) in loop that replaces array allocated before loop (rebind pair of `lifecycle` stage)
when broadcast reads no array but that buffer, keeps its type, and no code sees old array after rebind. Fix assigns
in place: `x .= f.(x)`.

## Rationale
Each iteration allocates new array and drops old one. In-place broadcast writes into buffer: one array serves whole
loop.

## Example
```julia
function decay(n::Int)
    x = ones(4)
    for _ in 1:n
        x = x .* 0.5
    end
    return x
end
```

## Alternative
```julia
function decay(n::Int)
    x = ones(4)
    for _ in 1:n
        x .= x .* 0.5
    end
    return x
end
```

## Limitations
Fix tier is `likely`: package call that keeps array but returns no array hides alias, and `.=` then changes array it
keeps. Broadcast with array operand other than buffer passes: its axes can differ. Fix needs buffer and broadcast assigned to
one plain name (`x = ones(n)`, then `x = f.(x)`), and dot syntax or `@.` on right side; else fix is `manual`.
"""
module BroadcastRebind

using ...Facts

const NAME = Symbol("broadcast-rebind")

"""Byte of `=` token between `name` and `value` of assignment: first `=` outside comments (`x #= a = b =# = y`)."""
function assignment_byte(file::SyntaxFile, name::SyntaxNode, value::SyntaxNode)::Int
    gap = (span(file, name).last_byte + 1):(span(file, value).first_byte - 1)
    hidden = comments_in(file, gap)
    found = findfirst(byte -> codeunit(file.text, byte) == UInt8('=') && !any(comment -> byte in comment, hidden), gap)
    # Parser read assignment, so `=` token lies in gap.
    return gap[something(found)]
end

"""Name and value nodes of assignment to plain name whose value spans `site`; `nothing` when none."""
function assignment(file::SyntaxFile, site::Span)::Union{Nothing, Tuple{SyntaxNode, SyntaxNode}}
    for node in forms(file, "=")
        name, value = children_of(node)
        kind_name(name) == "Identifier" && span(file, value) == site && return (name, value)
    end
    return nothing
end

"""
Fix that turns assignment of broadcast at `site` into in-place broadcast: `x = f.(x)` → `x .= f.(x)`. `manual` unless
buffer at `earlier` and broadcast are values of assignments to one plain name, and broadcast is dot syntax.
"""
function in_place_fix(files::AbstractDict{String, SyntaxFile}, site::Span, earlier::Span)::Fix
    text = "assign in place with `.=`: broadcast writes into buffer"
    file = get(files, site.file, nothing)
    isnothing(file) && return manual_fix(text)
    target, buffer = assignment(file, site), assignment(file, earlier)
    (isnothing(target) || isnothing(buffer)) && return manual_fix(text)
    name, value = something(target)
    # Other name (`x = (y = f.(x))`) can be local that `.=` finds unassigned.
    source(file, name) == source(file, first(something(buffer))) || return manual_fix(text)
    # `.=` fuses only dot syntax; `x .= materialize(bc)` still allocates, then copies.
    (kind_name(value) == "dotcall" || base_macro(value) in ("@.", "@__dot__")) || return manual_fix(text)
    equals = assignment_byte(file, name, value)
    return Fix(text, [Edit(Span(site.file, equals, equals - 1, Precision.exact), ".")], Tier.likely)
end

"""Findings for each loop broadcast that replaces buffer, keeps its type and axes, and that loop alone sees."""
function findings(facts::FactSet)::Vector{Finding}
    lifecycle = facts.lifecycle
    isnothing(lifecycle) && return Finding[]
    files, found = Dict(file.path => file for file in facts.files), Finding[]
    for method in lifecycle.methods, array in method.arrays
        isnothing(array.rebind) && continue
        pair = something(array.rebind)
        (pair.same_axes && pair.same_type && pair.exclusive) || continue
        push!(
            found, Finding(
                NAME, :broadcast_rebind, Confidence.definite, "loop replaces buffer with new broadcast array each iteration",
                Label(array.site, "allocates new array each iteration"), [Label(pair.earlier, "buffer it replaces")],
                "in-place broadcast writes into buffer: one array serves whole loop", in_place_fix(files, array.site, pair.earlier),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.performance, [41], Stage.lifecycle, findings)

end
