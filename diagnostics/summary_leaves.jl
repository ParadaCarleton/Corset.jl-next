# Where two runs first disagree: variants whose summary differs while every callee summary agrees.
# Usage: julia diagnostics/summary_leaves.jl <summaries-1.txt> <summaries-2.txt>
# Inputs come from `dump_facts.jl`. A leaf difference starts in the variant itself: its own IR or solve step.

"""Summary text and callee keys of each variant in summary dump `path`."""
function load_summaries(path::String)::Dict{String, Tuple{String, Vector{String}}}
    table = Dict{String, Tuple{String, Vector{String}}}()
    for line in eachline(path)
        key, summary, callees = split(line, '\t')
        table[key] = (summary, filter!(!isempty, String.(split(callees, '\x1f'))))
    end
    return table
end

"""Print variant counts, differing summaries, and up to 15 leaf differences of dumps `first_path` and `second_path`."""
function compare(first_path::String, second_path::String)::Nothing
    first_run, second_run = load_summaries(first_path), load_summaries(second_path)
    shared = intersect(keys(first_run), keys(second_run))
    println("variants: ", length(first_run), " vs ", length(second_run), "; only first ", length(setdiff(keys(first_run), keys(second_run))), "; only second ", length(setdiff(keys(second_run), keys(first_run))))
    differ = Set(key for key in shared if first(first_run[key]) != first(second_run[key]))
    println("summaries differ: ", length(differ))
    agrees(callee::String)::Bool = !(callee in differ) && get(first_run, callee, nothing) == get(second_run, callee, nothing)
    leaves = sort!([key for key in differ if all(callee -> callee == key || agrees(callee), last(first_run[key]))]; by = length)
    println("leaf differences: ", length(leaves))
    foreach(key -> println("LEAF ", first(key, 300)), first(leaves, 15))
    return nothing
end

compare(ARGS[1], ARGS[2])
