# Self-alias calls of name tier (F50; `phase5.md`, row 7): `!` call that reads memory it writes through other operand.

"""Self-alias calls of `walk`, with `spans` of its IR statements (`self_alias`)."""
function self_aliases(walk::Walk, spans::AbstractVector{Span})::Vector{SelfAlias}
    found = SelfAlias[]
    for index in 1:length(walk.ir.stmts)
        call = self_alias(walk, index)
        isnothing(call) && continue
        callee, confidence = call
        push!(found, SelfAlias(spans[index], callee, confidence))
    end
    return unique!(found)
end

"""
Writing function name and confidence of `!` call at statement `index` of `walk` whose other operand is written operand
(same object) or shares its memory through view. Same object to `ALIAS_BREAKS` function gives `definite`; shared memory
to warned function (`aliasing_warned`) gives `possible`. `nothing` for other statement and `UNALIAS_FUNCTIONS` callee.
"""
function self_alias(walk::Walk, index::Integer)::Union{Nothing, Tuple{String, Confidence.T}}
    statement = walk.ir.stmts[index][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    callee, operands = call_parts(walk, statement)
    (isnothing(operands) || !bang_function(callee) || callee in UNALIAS_FUNCTIONS) && return nothing
    position = written_position(walk, callee, operands)
    isnothing(position) && return nothing
    entry, breaks = alias_entry(callee)
    written, same, shared = operands[position], false, false
    sources = origins(walk, written)
    for (other, operand) in enumerate(operands)
        (other == position || callable(walk, operand)) && continue
        # Table entry that names input position leaves other inputs safe.
        (isnothing(entry) || other == entry) || continue
        if same_object(walk, written, operand)
            same = true
        else
            shared |= shares_memory(walk, sources, operand)
        end
    end
    same && breaks && return (string(nameof(callee)), Confidence.definite)
    (shared && (breaks || aliasing_warned(walk, callee, operands))) || return nothing
    return (string(nameof(callee)), Confidence.possible)
end

"""`ALIAS_BREAKS` entry of `callee`: input position (`nothing`: any input), and whether table holds `callee`."""
function alias_entry(@nospecialize(callee::Any))::Tuple{Union{Nothing, Int}, Bool}
    owner = library_owner(callee)
    isnothing(owner) && return (nothing, false)
    key = (owner, nameof(callee))
    return haskey(ALIAS_BREAKS, key) ? (ALIAS_BREAKS[key], true) : (nothing, false)
end

"""
Whether IR operands `first` and `second` are one object: one `underlying` value, or one place (`same_place`). View
result takes place of its parent, yet two views of one place can differ, so view result needs one value.
"""
function same_object(walk::Walk, @nospecialize(first::Any), @nospecialize(second::Any))::Bool
    underlying(walk, first) === underlying(walk, second) && return true
    (view_result(walk, first) || view_result(walk, second)) && return false
    return same_place(walk, first, second)
end

"""Whether IR `operand`, after `π` nodes and `identity` calls, is result of view call (`ALIAS_FUNCTIONS`)."""
function view_result(walk::Walk, @nospecialize(operand::Any))::Bool
    value = underlying(walk, operand)
    value isa Core.SSAValue || return false
    statement = walk.ir.stmts[value.id][:stmt]
    statement isa Expr || return false
    statement.head === :call || return false
    return call_parts(walk, statement)[1] in ALIAS_FUNCTIONS
end

"""IR value that `operand` passes on unchanged through `π` nodes and `identity` calls, or `operand` itself."""
function underlying(walk::Walk, @nospecialize(operand::Any))::Any
    while operand isa Core.SSAValue
        statement = walk.ir.stmts[operand.id][:stmt]
        if statement isa Core.PiNode
            operand = statement.val
        elseif statement isa Expr && statement.head === :call && call_parts(walk, statement)[1] === identity
            operand = statement.args[2]
        else
            break
        end
    end
    return operand
end

"""Whether `operand` shares memory with value of `sources` (its `origins`): common origin, or origins at one place."""
function shares_memory(walk::Walk, sources::Base.IdSet{Any}, @nospecialize(operand::Any))::Bool
    others = origins(walk, operand)
    return any(origin -> origin in sources || any(source -> same_place(walk, source, origin), sources), others)
end

"""
Whether docstring of method of `callee` that `operands` match carries Base aliasing warning (`Base._DOCS_ALIASING_WARNING`):
"Behavior can be unexpected when any mutated argument shares memory with any other argument."
"""
function aliasing_warned(walk::Walk, @nospecialize(callee::Function), operands::AbstractVector{Any})::Bool
    owner = parentmodule(callee)
    # Default `meta` call defines docstring table in module that lacks one.
    table = Docs.meta(owner; autoinit = false)
    isnothing(table) && return false
    docs = get(table, Docs.Binding(owner, nameof(callee)), nothing)
    isnothing(docs) && return false
    types = Tuple{Any[operand_type(walk, operand) for operand in operands]...}
    for (signature, doc) in docs.docs
        (signature === Union{} || types <: signature) || continue
        occursin(Base._DOCS_ALIASING_WARNING, join(doc.text)) && return true
    end
    return false
end
