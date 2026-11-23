"""Apply fix edits to source text, filtered by tier."""
module Fixes

using ..Facts: Finding, Edit, Tier

"""Whether edits `left` and `right` touch same bytes of one file."""
overlap(left::Edit, right::Edit)::Bool =
    left.span.file == right.span.file && left.span.first_byte <= right.span.last_byte && right.span.first_byte <= left.span.last_byte

"""
Edits of `findings` in every file whose fix tier is at most `tier`; `manual` fixes never apply.
Fix whose edits overlap edit chosen earlier, in any file, is skipped whole; next fix run applies it.
"""
function applicable_edits(findings::AbstractVector{Finding}, tier::Tier.T)::Vector{Edit}
    allowed = tier == Tier.manual ? Tier.breaking : tier
    chosen = Edit[]
    for finding in findings
        (isnothing(finding.fix) || finding.fix.tier > allowed) && continue
        edits = finding.fix.edits
        any(edit -> any(other -> overlap(edit, other), chosen), edits) || append!(chosen, edits)
    end
    return chosen
end

"""`text` of one file with its `edits` applied. Overlapping edits throw: two fixes would fight over same bytes."""
function apply_edits(text::String, edits::AbstractVector{Edit})::String
    allequal(edit.span.file for edit in edits) || throw(ArgumentError("edits of several files"))
    # Insertion (empty span) before edit at same byte goes first.
    ordered = sort(edits; by = edit -> (edit.span.first_byte, edit.span.last_byte))
    for (left, right) in zip(ordered, Iterators.drop(ordered, 1))
        left.span.last_byte < right.span.first_byte || throw(ArgumentError("overlapping edits at byte $(right.span.first_byte)"))
    end
    bytes = codeunits(text)
    pieces = String[]
    cursor = 1
    for edit in ordered
        push!(pieces, String(bytes[cursor:(edit.span.first_byte - 1)]), edit.replacement)
        cursor = edit.span.last_byte + 1
    end
    push!(pieces, String(bytes[cursor:end]))
    return join(pieces)
end

end
