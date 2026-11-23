"""Indexes of call statements among `statements` whose value no statement reads: Julia runs them for effect only."""
function unused_calls(statements::AbstractVector{Any})::BitSet
    Base.require_one_based_indexing(statements)
    used = BitSet()
    foreach(statement -> CC.scan_ssa_use!(push!, used, statement), statements)
    return BitSet(index for (index, statement) in enumerate(statements) if statement isa Expr && statement.head === :call && !(index in used))
end

"""Call statements of method of `site` whose value Julia drops (`Facts.discarded`), by line in file with line `starts`."""
function discarded_calls(site::MethodSite, starts::AbstractVector{<:Integer})::Dict{Int, Vector{SyntaxNode}}
    # Position in `starts` is line number.
    Base.require_one_based_indexing(starts)
    found = Dict{Int, Vector{SyntaxNode}}()
    isnothing(site.node) && return found
    for node in Facts.descendants(site.node)
        kind_name(node) in ("call", "juxtapose") && Facts.discarded(node) || continue
        push!(get!(Vector{SyntaxNode}, found, searchsortedlast(starts, first(Facts.trimmed_bytes(site.file.text, node)))), node)
    end
    return found
end

"""
Nodes of unused call statements of `code` that `nodes` leaves without node, by statement, among discarded call
statements `candidates` by line. Statements of one callee and argument count on one line map in evaluation order:
inner call ends first. Counts must agree, so unreached statements, which inference wraps in `Core.Const`, count too.
Second result holds statements whose counts disagree (`finally` body lowers twice). TypedSyntax.jl maps no statement
whose value code drops.
"""
function discarded_nodes(file::SyntaxFile, code::Core.CodeInfo, nodes::AbstractVector{Union{Nothing, SyntaxNode}}, lines::AbstractVector{<:Integer}, candidates::AbstractDict{<:Integer, <:AbstractVector{SyntaxNode}})::Tuple{Dict{Int, SyntaxNode}, BitSet}
    Base.require_one_based_indexing(nodes, lines)
    found, unmapped = Dict{Int, SyntaxNode}(), BitSet()
    isempty(candidates) && return found, unmapped
    # Unreached callee reference is wrapped too, so callee names resolve in unwrapped copy.
    unwrapped = copy(code)
    unwrapped.code = Any[Widening.unwrapped(statement) for statement in code.code]
    taken = Base.IdSet{SyntaxNode}(node for node in nodes if !isnothing(node))
    groups = Dict{Tuple{Int, Symbol, Int}, Vector{Int}}()
    for index in unused_calls(unwrapped.code)
        (isnothing(nodes[index]) && lines[index] > 0) || continue
        statement = unwrapped.code[index]::Expr
        name = callee_name(unwrapped, statement)
        isnothing(name) || push!(get!(Vector{Int}, groups, (lines[index], name, length(statement.args) - 1)), index)
    end
    for ((line, name, arguments), indexes) in groups
        spelled = [node for node in get(candidates, line, SyntaxNode[]) if !(node in taken) && spells_call(file, node, name, arguments)]
        isempty(spelled) && continue
        length(spelled) == length(indexes) || (union!(unmapped, indexes); continue)
        sort!(spelled; by = node -> last(Facts.trimmed_bytes(file.text, node)))
        for (index, node) in zip(indexes, spelled)
            found[index] = node
        end
    end
    return found, unmapped
end
