"""`loop-order` (F42): inner loop runs over non-first index; Julia arrays are column-major."""
module LoopOrder

using ...Facts

const NAME = Symbol("loop-order")

"""Loop variable names of `for` node, in iteration order (`for i in a, j in b` gives `i`, `j`)."""
function loop_variables(loop)::Vector{String}
    names = String[]
    for clause in children_of(children_of(loop)[1])
        target = children_of(clause)[1]
        isnothing(identifier_name(target)) || push!(names, identifier_name(target))
    end
    return names
end

"""Loop variables of loops enclosing `node`, outermost first, with innermost loop node."""
function enclosing_loops(node)::Tuple{Vector{String}, Any}
    loops = filter(ancestor -> kind_name(ancestor) == "for", ancestors(node))
    isempty(loops) && return String[], nothing
    return reduce(vcat, (loop_variables(loop) for loop in reverse(loops))), loops[1]
end

"""Findings for indexing whose first index varies in outer loop and later index in innermost loop; `possible`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        reported = Set{Any}()
        for reference in nodes_named(file, "ref")
            indices = [identifier_name(index) for index in children_of(reference)[2:end]]
            length(indices) >= 2 && all(!isnothing, indices) || continue
            variables, innermost = enclosing_loops(reference)
            length(variables) >= 2 && innermost ∉ reported || continue
            inner = variables[end]
            position = findfirst(==(inner), indices)
            !isnothing(position) && position > 1 && indices[1] in variables[1:(end - 1)] || continue
            push!(reported, innermost)
            push!(
                found, finding(
                    NAME, file, reference; kind = :row_major, confidence = Confidence.possible,
                    message = "innermost loop over `$inner` walks index $position of `$(source(file, children_of(reference)[1]))`",
                    label = "strided access", why = "arrays store first index contiguously; inner loop should run over first index",
                    fix = manual_fix("swap loops so `$(indices[1])` varies fastest"),
                    causes = [Label(span(file, children_of(innermost)[1]), "innermost loop")],
                )
            )
        end
    end
    return found
end

const ENTRY = CheckEntry(NAME, Group.performance, [42], Family.A, run)

end
