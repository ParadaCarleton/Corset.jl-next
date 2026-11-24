# Package closures a call can invoke, and writes of their bodies (`effects.md`, Writes, source 5).

"""Package closure that IR operand holds: its type, and operands its `new` statement captures, by field position."""
struct HeldClosure
    type::DataType
    captures::Vector{Any}
end

# corset: allow bang-convention -- memo of closure writes in walk; result never changes
"""
Events of package closures that call `call`, statement `index`, of `callee` with `operands` can invoke (`effects.md`,
Writes, source 5), and their writes. Closure body writes through captured fields map onto operands its `new` statement
captured; writes below global stay on global. Writes keep fresh captured objects, which give no event.
"""
function closure_events(walk::Walk, call::Expr, index::Integer, @nospecialize(callee::Any), operands::AbstractVector{Any})::Tuple{Vector{Event}, Vector{ClosureWrite}}
    found, writes = Event[], ClosureWrite[]
    closures = HeldClosure[held for operand in invoked_operands(walk, call, callee, operands) for held in held_closures(walk, operand)]
    isempty(closures) && return found, writes
    proven_call(walk, index, call, call_callee(walk, call)) && return found, writes
    for held in closures, write in closure_writes!(walk, held.type)
        confidence = write.exact ? Confidence.definite : Confidence.possible
        if write.target isa GlobalRef
            place = Place.At(Root.Global(write.target), NO_STEPS)
            push!(found, Event(place, true, place_kind(walk, place, write.kind), confidence, true))
        else
            write.target <= length(held.captures) || continue
            events = value_events(walk, operand_value(walk, held.captures[write.target]), write.kind, true, true)
            append!(found, (Event(event.place, event.below, event.kind, max(event.confidence, confidence), true) for event in events))
        end
        push!(writes, write)
    end
    return found, writes
end

"""
Package closures IR `operand` holds (`held_closure`): closure itself, or value of keyword tuple that `Core.kwcall`
takes (`NamedTuple{names}(tuple)`).
"""
function held_closures(walk::Walk, @nospecialize(operand::Any))::Vector{HeldClosure}
    held = held_closure(walk, operand)
    isnothing(held) || return HeldClosure[held]
    keywords = operand isa Core.SSAValue ? walk.ir.stmts[operand.id][:stmt] : nothing
    keywords isa Expr || return HeldClosure[]
    (keywords.head === :call && length(keywords.args) == 2 && keywords.args[2] isa Core.SSAValue) || return HeldClosure[]
    type = constant_value(walk, keywords.args[1])
    (type isa Type && type <: NamedTuple) || return HeldClosure[]
    values = walk.ir.stmts[(keywords.args[2]::Core.SSAValue).id][:stmt]
    values isa Expr || return HeldClosure[]
    (values.head === :call && constant_value(walk, values.args[1]) === Core.tuple) || return HeldClosure[]
    return HeldClosure[something(held_closure(walk, value)) for value in values.args[2:end] if !isnothing(held_closure(walk, value))]
end

"""
Operands that call `call` of `callee` can invoke: called function, and operands of function that calls its function
arguments. Builtin, constructor, tuple, alias and choice function return or store operands; `!` call stores
operands after written one.
"""
function invoked_operands(walk::Walk, call::Expr, @nospecialize(callee::Any), operands::AbstractVector{Any})::Vector{Any}
    Base.require_one_based_indexing(operands)
    invoked = Any[call.args[1]]
    # Keyword call takes keyword tuple and function before positional operands.
    constant_value(walk, call.args[1]) === Core.kwcall && length(call.args) >= 3 && append!(invoked, call.args[2:3])
    (callee isa Core.Builtin || callee isa Type || callee === Core.tuple || callee in ALIAS_FUNCTIONS || callee in CHOICE_FUNCTIONS) && return invoked
    written = bang_function(callee) ? written_position(walk, callee, operands) : nothing
    return append!(invoked, operands[1:(something(written, length(operands) + 1) - 1)])
end

"""
Package closure that IR `operand` holds: `new` statement of closure, or anonymous function instance that captures
nothing, which IR can hold as constant (`anonymous_function`).
"""
function held_closure(walk::Walk, @nospecialize(operand::Any))::Union{Nothing, HeldClosure}
    built = operand isa Core.SSAValue ? walk.ir.stmts[operand.id][:stmt] : nothing
    if built isa Expr && built.head === :new
        type, captures = constant_value(walk, built.args[1]), built.args[2:end]
    else
        instance = constant(walk.ir, operand)
        isnothing(instance) && return nothing
        type, captures = typeof(something(instance)), Any[]
        type isa DataType && anonymous_function(type) || return nothing
    end
    return type isa DataType && type <: Function && parentmodule(type) in walk.modules ? HeldClosure(type, captures) : nothing
end

"""
Whether singleton `type` is anonymous function that lowering names (`#` name): no global holds its instance. Named
function and keyword body have global; their name stands in for their body.
"""
function anonymous_function(type::DataType)::Bool
    (type <: Function && isdefined(type, :instance) && startswith(String(nameof(type)), '#')) || return false
    owner, name = parentmodule(type), nameof(type.instance)
    return !(isdefined(owner, name) && getglobal(owner, name) === type.instance)
end

"""
Captured fields of closure `type` that its methods write, by field position: `!` call or builtin store on captured
field or below it, in lowered code. Lowered code has no types: callable skip reads constant callees.
"""
function closure_writes!(walk::Walk, type::DataType)::Vector{ClosureWrite}
    haskey(walk.closures, type) && return walk.closures[type]
    walk.closures[type] = ClosureWrite[]
    found = ClosureWrite[]
    # `methods(type)` lists constructors; call methods match call signature of closure instance.
    matches = Base._methods_by_ftype(Tuple{type, Vararg{Any}}, -1, walk.world)
    for method in (matches isa Vector ? Method[(match::Core.MethodMatch).method for match in matches] : Method[])
        (isdefined(method, :source) && method.source !== nothing) || continue
        code = Base.uncompressed_ast(method)
        captured, slots, assignments, written, globals = Dict{Int, Set{Int}}(), Dict{Int, Set{Int}}(), Dict{Int, Int}(), Set{Int}[], Set{GlobalRef}()
        # Loop can assign local after write through it: scan again until field sets stop growing.
        while true
            held = field_count(captured, slots)
            empty!(assignments)
            empty!(written)
            empty!(globals)
            closure_scan!(code, type, captured, slots, assignments, written, globals)
            field_count(captured, slots) == held && break
        end
        # Local assigned twice can hold other object when it writes.
        exact = all(slot -> assignments[slot] == 1, keys(slots))
        append!(found, (ClosureWrite(field, EffectKind.memory, exact && length(fields) == 1) for fields in written for field in fields))
        append!(found, (ClosureWrite(binding, EffectKind.memory, true) for binding in globals))
    end
    walk.closures[type] = unique!(found)
    return walk.closures[type]
end

"""Count of captured fields over every statement and local: sets only grow, so equal count means no change."""
field_count(captured::AbstractDict{<:Integer, <:AbstractSet{<:Integer}}, slots::AbstractDict{<:Integer, <:AbstractSet{<:Integer}})::Int = sum(length, values(captured); init = 0) + sum(length, values(slots); init = 0)

"""
One scan of lowered `code` of closure `type`: grows captured fields of each statement (`captured`) and local
(`slots`), counts assignments of each local, adds captured fields of each written operand to `written`, and adds global
binding written operand names to `globals`.
"""
function closure_scan!(code::Core.CodeInfo, type::DataType, captured::AbstractDict{<:Integer, <:AbstractSet{<:Integer}}, slots::AbstractDict{<:Integer, <:AbstractSet{<:Integer}}, assignments::AbstractDict{<:Integer, <:Integer}, written::AbstractVector{<:AbstractSet{<:Integer}}, globals::AbstractSet{GlobalRef})::Nothing
    for (index, statement) in enumerate(code.code)
        # Local that holds captured field: `out = self.out` before `push!(out, x)`. Scan ignores flow, so it never clears.
        assigned = statement isa Expr && statement.head === :(=) && statement.args[1] isa Core.SlotNumber ? statement.args[1]::Core.SlotNumber : nothing
        if assigned isa Core.SlotNumber
            assignments[assigned.id] = get(assignments, assigned.id, 0) + 1
            statement = (statement::Expr).args[2]
        end
        fields = held_fields(code, type, captured, slots, statement)
        if !isempty(fields)
            union!(get!(Set{Int}, captured, index), fields)
            assigned isa Core.SlotNumber && union!(get!(Set{Int}, slots, assigned.id), fields)
        end
        rebound = assigned_global(code, statement)
        isnothing(rebound) || (push!(globals, rebound); continue)
        statement isa Expr || continue
        statement.head === :call || continue
        callee = lowered_constant(code, statement.args[1])
        callee === setfield! || bang_function(callee) || continue
        operands = @view(statement.args[2:end])
        position = findfirst(operand -> !(lowered_constant(code, operand) isa Union{Function, Type}), operands)
        isnothing(position) && continue
        push!(written, copy(captured_source(captured, slots, operands[position])))
        binding = lowered_global(code, operands[position])
        isnothing(binding) || push!(globals, binding)
    end
    return nothing
end

"""
Captured fields of closure `type` that lowered `expression` of `code` holds: load from closure or below captured
field, statement in `captured`, or local in `slots`.
"""
function held_fields(code::Core.CodeInfo, type::DataType, captured::AbstractDict{<:Integer, <:AbstractSet{<:Integer}}, slots::AbstractDict{<:Integer, <:AbstractSet{<:Integer}}, @nospecialize(expression::Any))::Set{Int}
    expression isa Expr || return captured_source(captured, slots, expression)
    expression.head === :call || return Set{Int}()
    length(expression.args) >= 2 || return Set{Int}()
    callee = lowered_constant(code, expression.args[1])
    callee === getfield || callee === getproperty || callee === getindex || return Set{Int}()
    source = expression.args[2]
    (source isa Core.SlotNumber && source.id == 1) || return captured_source(captured, slots, source)
    field = length(expression.args) >= 3 ? captured_field(type, expression.args[3]) : nothing
    return isnothing(field) ? Set{Int}() : Set{Int}([field])
end

"""Captured fields that lowered `operand` holds: statement in `captured` or local in `slots`."""
function captured_source(captured::AbstractDict{<:Integer, <:AbstractSet{<:Integer}}, slots::AbstractDict{<:Integer, <:AbstractSet{<:Integer}}, @nospecialize(operand::Any))::Set{Int}
    operand isa Core.SSAValue && return get(captured, operand.id, Set{Int}())
    operand isa Core.SlotNumber && operand.id != 1 && return get(slots, operand.id, Set{Int}())
    return Set{Int}()
end

"""Global binding lowered operand `operand` of `code` names, directly or by statement; `nothing` for other operand."""
function lowered_global(code::Core.CodeInfo, @nospecialize(operand::Any))::Union{Nothing, GlobalRef}
    operand isa Core.SSAValue && return lowered_global(code, code.code[operand.id])
    return operand isa GlobalRef ? operand : nothing
end

"""Global binding lowered `statement` of `code` assigns: `=` to global or `setglobal!` family call; `nothing` else."""
function assigned_global(code::Core.CodeInfo, @nospecialize(statement::Any))::Union{Nothing, GlobalRef}
    statement isa Expr || return nothing
    statement.head === :(=) && return statement.args[1] isa GlobalRef ? statement.args[1]::GlobalRef : nothing
    (statement.head === :call && length(statement.args) >= 3 && lowered_constant(code, statement.args[1]) in GLOBAL_BUILTINS) || return nothing
    mod, name = lowered_constant(code, statement.args[2]), lowered_constant(code, statement.args[3])
    return mod isa Module && name isa Symbol ? GlobalRef(mod, name) : nothing
end

"""
Value of lowered operand `operand` of `code` when it names constant global or module, directly or by statement;
`nothing` else.
"""
function lowered_constant(code::Core.CodeInfo, @nospecialize(operand::Any))::Any
    operand isa Core.SSAValue && return lowered_constant(code, code.code[operand.id])
    operand isa GlobalRef && return isdefinedglobal(operand.mod, operand.name) && isconst(operand) ? getglobal(operand.mod, operand.name) : nothing
    operand isa QuoteNode && return operand.value
    return operand isa Module ? operand : nothing
end

"""Position of field of closure `type` that lowered field operand `name` names; `nothing` for other operand."""
function captured_field(type::DataType, @nospecialize(name::Any))::Union{Nothing, Int}
    name isa QuoteNode && (name = name.value)
    name isa Symbol || return nothing
    position = findfirst(==(name), fieldnames(type))
    # `Core.Box` field holds local variable that closure reassigns; caller cannot see that write.
    return isnothing(position) || fieldtype(type, position) === Core.Box ? nothing : position
end
