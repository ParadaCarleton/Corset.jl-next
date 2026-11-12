"""Apply fix edits to source text, filtered by tier."""
module Fixes

using ..Facts: Finding, Edit, Tier

"""Edits of `findings` in `file` whose fix tier is at most `tier`; `manual` fixes never apply."""
function applicable_edits(findings::Vector{Finding}, file::String, tier::Tier.T)::Vector{Edit}
    allowed = tier == Tier.manual ? Tier.breaking : tier
    return [
        edit for finding in findings if !isnothing(finding.fix) && finding.fix.tier <= allowed
            for edit in finding.fix.edits if edit.span.file == file
    ]
end

"""`text` with `edits` applied. Overlapping edits throw: two fixes would fight over same bytes."""
function apply_edits(text::String, edits::Vector{Edit})::String
    ordered = sort(edits; by = edit -> edit.span.first_byte)
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
