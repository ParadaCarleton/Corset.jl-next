"""`one-based-range` (F36): `1:length(a)` assumes indices start at 1; `OffsetArray` breaks it."""
module OneBasedRange

using ...Facts

const NAME = Symbol("one-based-range")
const LENGTH_RULE = Rule(@pattern ~or(1:length({a}), 1:lastindex({a})))
const SIZE_RULE = Rule(@pattern 1:size({a}, {d}))

"""Findings for ranges built from `1` and array length; syntax cannot see index type, so `possible`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        for match in matches(file, LENGTH_RULE)
            push!(found, range_finding(file, match.node, "eachindex($(source(file, binding(match, :a))))"))
        end
        for match in matches(file, SIZE_RULE)
            push!(found, range_finding(file, match.node, "axes($(source(file, binding(match, :a))), $(source(file, binding(match, :d))))"))
        end
    end
    return found
end

"""Whether range `node` indexes array or drives `for` loop; other uses would see changed values."""
function index_position(node)::Bool
    parent = parent_of(node)
    isnothing(parent) && return false
    kind_name(parent) == "ref" && return true
    grandparent = parent_of(parent)
    return kind_name(parent) in ("in", "=", "∈") && !isnothing(grandparent) && kind_name(grandparent) in ("iteration", "for")
end

"""Fix replacing `node` by `replacement` in index or loop position; manual elsewhere."""
range_fix(file::SyntaxFile, node, replacement::String)::Fix = index_position(node) ?
    replace_fix(file, node, replacement, Tier.likely) : manual_fix("use `$replacement` if range indexes array")

"""Finding for one-based range `node`, fixed by `replacement`."""
range_finding(file::SyntaxFile, node, replacement::String)::Finding = finding(
    NAME, file, node; kind = :length_range, confidence = Confidence.possible,
    message = "`$(source(file, node))` assumes indices start at 1",
    label = "breaks on arrays with other first index",
    why = "arrays such as `OffsetArray` index from other values; this range then reads wrong elements or throws",
    fix = range_fix(file, node, replacement),
)

const ENTRY = CheckEntry(NAME, Group.composability, [36], Family.A, run)

end
