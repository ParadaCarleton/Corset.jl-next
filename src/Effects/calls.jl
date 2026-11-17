"""Operand of call: IR `Value`, or `Part` at position of tuple value that `_apply_iterate` spreads."""
@data Operand begin
    Value(Any)
    Part(Any, Int)
end

"""
Call statement resolution (`effects.md`, Calls): `Builtin` or `Intrinsic` with operands after callee; `Static` instance
with operands, callee first; `Open` call with operands; `Dead` when `invoke` selects no method of argument types.
"""
@data Outcome begin
    Builtin(Any, Vector{Operand.Type})
    Intrinsic(Any, Vector{Operand.Type})
    Static(Core.MethodInstance, Vector{Operand.Type})
    Open(Vector{Operand.Type})
    Dead()
end

"""Type of `operand` in `ir`."""
function operand_type(ir::CC.IRCode, operand::Operand.Type)::Any
    return @match operand begin
        Operand.Value(value) => value_type(ir, value)
        Operand.Part(value, position) => fieldtype(value_type(ir, value), position)
    end
end

"""Instance call with argument `types` reaches when one method matches in `world`; `nothing` otherwise."""
function dispatch(types::Vector{Any}, world::UInt)::Union{Nothing, Core.MethodInstance}
    matches = Base._methods_by_ftype(Tuple{types...}, 1, world)
    matches isa Vector || return nothing
    length(matches) == 1 || return nothing
    return CC.specialize_method(only(matches)::Core.MethodMatch)
end

"""
Resolution of call with `operands` (callee first) in `ir`: builtin, intrinsic, one matching method, else open. Builtins
that call operand (`invokelatest`, `_apply_iterate`, `finalizer`) resolve to call they make.
"""
function resolve(ir::CC.IRCode, operands::Vector{Operand.Type}, world::UInt)::Outcome.Type
    types = Any[operand_type(ir, operand) for operand in operands]
    callee = @match first(operands) begin
        Operand.Value(value) => constant(ir, value)
        Operand.Part(_, _) => nothing
    end
    if !isnothing(callee) && something(callee) isa Core.Builtin
        builtin = something(callee)
        builtin isa Core.IntrinsicFunction && return Outcome.Intrinsic(builtin, operands[2:end])
        builtin === Core._apply_iterate && return spread_call(ir, operands[3:end], world)
        builtin in (Core.invokelatest, Core._call_latest, Core.finalizer) && return resolve(ir, operands[2:end], world)
        builtin in (Core.invoke_in_world, Core._call_in_world, Core._call_in_world_total) && return resolve(ir, operands[3:end], world)
        builtin === Core.invoke && return invoke_call(ir, operands, types, world)
        return Outcome.Builtin(builtin, operands[2:end])
    end
    instance = dispatch(types, world)
    return isnothing(instance) ? Outcome.Open(operands) : Outcome.Static(instance, operands)
end

"""Resolution of `_apply_iterate` call: callee and spread `arguments` tuples of known length become operands."""
function spread_call(ir::CC.IRCode, arguments::Vector{Operand.Type}, world::UInt)::Outcome.Type
    operands = Operand.Type[first(arguments)]
    for argument in arguments[2:end]
        value = @match argument begin
            Operand.Value(value) => value
            Operand.Part(_, _) => return Outcome.Open(arguments)
        end
        type = value_type(ir, value)
        type isa DataType || return Outcome.Open(arguments)
        type <: Tuple && (isempty(type.parameters) || !Base.isvarargtype(type.parameters[end])) || return Outcome.Open(arguments)
        append!(operands, (Operand.Part(value, position) for position in 1:fieldcount(type)))
    end
    return resolve(ir, operands, world)
end

"""Resolution of `Core.invoke(f, T, args...)`: method `T` selects, specialized to argument `types`; open without it."""
function invoke_call(ir::CC.IRCode, operands::Vector{Operand.Type}, types::Vector{Any}, world::UInt)::Outcome.Type
    called = Operand.Type[operands[2]; operands[4:end]]
    selector = @match operands[3] begin
        Operand.Value(value) => constant(ir, value)
        Operand.Part(_, _) => nothing
    end
    isnothing(selector) && return Outcome.Open(called)
    match = Base._which(Tuple{types[2], something(selector).parameters...}; world, raise = false)
    isnothing(match) && return Outcome.Open(called)
    signature = typeintersect(Tuple{types[2], types[4:end]...}, match.method.sig)
    signature === Union{} && return Outcome.Dead()
    return Outcome.Static(CC.specialize_method(match.method, signature, match.sparams), called)
end

"""
Resolution of statement `statement` of `ir`: call or foreign call outcome; `nothing` for other statements. IR before
inlining holds no `:invoke` statement.
"""
function statement_outcome(ir::CC.IRCode, statement::Any, world::UInt)::Union{Nothing, Outcome.Type}
    statement isa Expr || return nothing
    statement.head === :call && return resolve(ir, Operand.Type[Operand.Value(value) for value in statement.args], world)
    # Foreign call table comes with call resolution (`phase5.md`, PR 2); until then every foreign call stays open.
    statement.head === :foreigncall && return Outcome.Open(Operand.Type[Operand.Value(value) for value in statement.args[6:end]])
    return nothing
end
