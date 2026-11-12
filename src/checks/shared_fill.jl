"""`shared-fill` (F35): `fill(zeros(3), n)` puts one mutable object in every slot."""
module SharedFill

using ...Facts

const NAME = Symbol("shared-fill")
const RULE = Rule(@pattern fill({value}, {dims}...))
"""Callees that return fresh mutable object."""
const MUTABLE_MAKERS = Set(
    [
        "zeros", "ones", "similar", "copy", "deepcopy", "rand", "randn", "fill", "Vector", "Matrix", "Array",
        "Dict", "Set", "IdDict", "Ref", "IOBuffer",
    ]
)

"""Whether `node` builds fresh mutable object: maker call, array literal or comprehension."""
function builds_mutable(node)::Bool
    kind_name(node) in ("vect", "ref", "comprehension", "typed_comprehension", "vcat", "hcat") && return true
    kind_name(node) == "call" || return false
    callee = children_of(node)[1]
    name = kind_name(callee) == "curly" ? children_of(callee)[1] : callee
    callee_name = identifier_name(name)
    return callee_name in MUTABLE_MAKERS && (callee_name != "rand" || length(children_of(node)) > 1)
end

"""Comprehension equal to `fill(value, dims...)` with one fresh value per slot."""
comprehension(value::String, dims::Vector{String})::String = "[$value for " * join(("_ in 1:$dim" for dim in dims), ", ") * "]"

"""Findings for `fill` whose value is fresh mutable object; harm needs later mutation, so `possible`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, match in matches(file, RULE)
        value = binding(match, :value)
        builds_mutable(value) || continue
        dims = [source(file, dim) for dim in children_of(match.node)[3:end]]
        plain = all(dim -> kind_name(dim) in ("Identifier", "Integer", "call", "."), children_of(match.node)[3:end])
        fix = plain && !isempty(dims) ? replace_fix(file, match.node, comprehension(source(file, value), dims), Tier.likely) :
            manual_fix("build one object per slot with comprehension")
        push!(
            found, finding(
                NAME, file, match.node; kind = :shared_mutable, confidence = Confidence.possible,
                message = "every element of `$(source(file, match.node))` is same object",
                label = "one object shared by all slots", why = "mutating one element changes all of them",
                fix, causes = [Label(span(file, value), "evaluated once")],
            )
        )
    end
    return found
end

const ENTRY = CheckEntry(NAME, Group.correctness, [35], Family.A, run)

end
