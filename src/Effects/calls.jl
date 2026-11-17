"""Operand of call: IR `Value`, or `Part` at position of tuple value that `_apply_iterate` spreads."""
@data Operand begin
    Value(Any)
    Part(Any, Int)
end

"""
Effects of known C function (`effects.md`, Calls, step 2), by argument position: arguments it writes and reads through;
`copies` of source elements into destination elements; `stores` of argument into destination elements; arguments result
points into; and arguments whose elements result may be.
"""
Base.@kwdef struct ForeignEffects
    writes::Vector{Int} = Int[]
    reads::Vector{Int} = Int[]
    copies::Vector{Pair{Int, Int}} = Pair{Int, Int}[]
    stores::Vector{Pair{Int, Int}} = Pair{Int, Int}[]
    result::Vector{Int} = Int[]
    elements::Vector{Int} = Int[]
end

"""
Foreign call table: C functions corpus reaches, from Base call sites and Julia runtime source. Pointer argument stands
for object it points into. Missing name stays open.
"""
const FOREIGN_EFFECTS = Dict{Symbol, ForeignEffects}(
    :memmove => ForeignEffects(writes = [1], reads = [2], copies = [1 => 2], result = [1]),
    :memcpy => ForeignEffects(writes = [1], reads = [2], copies = [1 => 2], result = [1]),
    :memset => ForeignEffects(writes = [1], result = [1]),
    :memcmp => ForeignEffects(reads = [1, 2]),
    :memchr => ForeignEffects(reads = [1], result = [1]),
    :memrchr => ForeignEffects(reads = [1], result = [1]),
    :strlen => ForeignEffects(reads = [1]),
    # Destination memory, its pointer, source memory, its pointer, count.
    :jl_genericmemory_copyto => ForeignEffects(writes = [1, 2], reads = [3, 4], copies = [1 => 3, 2 => 4]),
    :jl_object_id => ForeignEffects(reads = [1]),
    # Pointer of object, or object at pointer (`unsafe_pointer_to_objref`).
    :jl_value_ptr => ForeignEffects(result = [1]),
    :jl_string_ptr => ForeignEffects(result = [1]),
    :jl_symbol_name => ForeignEffects(result = [1]),
    :jl_symbol_n => ForeignEffects(reads = [1]),
    # `String` and type results point to no object effects track.
    :jl_alloc_string => ForeignEffects(),
    :jl_pchar_to_string => ForeignEffects(reads = [1]),
    # Memory shares bytes of string; string takes bytes of memory, which it empties.
    :jl_string_to_genericmemory => ForeignEffects(result = [1]),
    :jl_genericmemory_to_string => ForeignEffects(writes = [1], reads = [1]),
    :jl_genericmemory_owner => ForeignEffects(result = [1]),
    # `IdDict` table: memory, key, value or default, flag pointer. Rehashed table counts as same memory.
    :jl_eqtable_get => ForeignEffects(reads = [1], result = [3], elements = [1]),
    :jl_eqtable_put => ForeignEffects(writes = [1, 4], reads = [1], stores = [1 => 2, 1 => 3], result = [1]),
    :jl_eqtable_pop => ForeignEffects(writes = [1, 4], reads = [1], result = [3], elements = [1]),
    :jl_eqtable_nextind => ForeignEffects(reads = [1]),
    :jl_idtable_rehash => ForeignEffects(reads = [1], result = [1]),
    :jl_idset_peek_bp => ForeignEffects(reads = [1, 2]),
    :jl_type_unionall => ForeignEffects(),
    :jl_types_equal => ForeignEffects(),
    :jl_has_typevar => ForeignEffects(),
    :jl_stored_inline => ForeignEffects(),
    :jl_islayout_inline => ForeignEffects(writes = [2, 3]),
    :jl_get_world_counter => ForeignEffects(),
    :jl_get_tls_world_age => ForeignEffects(),
    :jl_rethrow => ForeignEffects(),
    :jl_rethrow_other => ForeignEffects(),
    :utf8proc_category => ForeignEffects(),
    Symbol("llvm.prefetch") => ForeignEffects(),
    :uv_cwd => ForeignEffects(writes = [1, 2], reads = [2]),
)

"""
Call statement resolution (`effects.md`, Calls): `Builtin` or `Intrinsic` with operands after callee; `Foreign` call
table entry with C arguments; `Dispatch` to instances of matching methods with operands, callee first: one is static
call, more join; `Open` call with operands; `Dead` when no method matches.
"""
@data Outcome begin
    Builtin(Any, Vector{Operand.Type})
    Intrinsic(Any, Vector{Operand.Type})
    Foreign(ForeignEffects, Vector{Operand.Type})
    Dispatch(Vector{Core.MethodInstance}, Vector{Operand.Type})
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

"""Most methods run-time dispatch joins (`effects.md`, Calls, step 5); never below compiler `max_methods`."""
const JOIN_LIMIT = 8

"""
Instances of methods call with argument `types` can reach in `world`, each specialized to call; `nothing` past
`JOIN_LIMIT` methods.
"""
function dispatch(types::Vector{Any}, world::UInt)::Union{Nothing, Vector{Core.MethodInstance}}
    matches = Base._methods_by_ftype(Tuple{types...}, JOIN_LIMIT, world)
    matches isa Vector || return nothing
    return Core.MethodInstance[CC.specialize_method(match::Core.MethodMatch) for match in matches]
end

"""
Resolution of call with `operands` (callee first) in `ir`: builtin, intrinsic, matching methods up to limit, else open.
Builtins that call operand (`invokelatest`, `_apply_iterate`, `finalizer`) resolve to call they make. Intrinsic operand
can be nested constant expression (`cglobal((:name, library))`), so operand types wait until dispatch.
"""
function resolve(ir::CC.IRCode, operands::Vector{Operand.Type}, world::UInt)::Outcome.Type
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
        builtin === Core.invoke && return invoke_call(ir, operands, world)
        return Outcome.Builtin(builtin, operands[2:end])
    end
    instances = dispatch(Any[operand_type(ir, operand) for operand in operands], world)
    isnothing(instances) && return Outcome.Open(operands)
    # No matching method: call throws `MethodError`.
    return isempty(instances) ? Outcome.Dead() : Outcome.Dispatch(instances, operands)
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
        definite_tuple(type) || return Outcome.Open(arguments)
        append!(operands, (Operand.Part(value, position) for position in 1:fieldcount(type)))
    end
    return resolve(ir, operands, world)
end

"""Resolution of `Core.invoke(f, T, args...)`: method `T` selects, specialized to argument types; open without it."""
function invoke_call(ir::CC.IRCode, operands::Vector{Operand.Type}, world::UInt)::Outcome.Type
    called = Operand.Type[operands[2]; operands[4:end]]
    types = Any[operand_type(ir, operand) for operand in called]
    selector = @match operands[3] begin
        Operand.Value(value) => constant(ir, value)
        Operand.Part(_, _) => nothing
    end
    isnothing(selector) && return Outcome.Open(called)
    match = Base._which(Tuple{types[1], something(selector).parameters...}; world, raise = false)
    isnothing(match) && return Outcome.Open(called)
    signature = typeintersect(Tuple{types...}, match.method.sig)
    signature === Union{} && return Outcome.Dead()
    return Outcome.Dispatch([CC.specialize_method(match.method, signature, match.sparams)], called)
end

"""Name of C function that foreign call `target` names: symbol or string, alone or first of library tuple."""
function foreign_name(target::Any)::Union{Nothing, Symbol}
    target isa QuoteNode && return foreign_name(target.value)
    target isa Expr && target.head === :tuple && !isempty(target.args) && return foreign_name(first(target.args))
    target isa Tuple && !isempty(target) && return foreign_name(first(target))
    target isa Symbol && return target
    target isa String && return Symbol(target)
    return nothing
end

"""
Resolution of foreign call `statement`: table entry with C arguments when table knows name; else open on every operand,
GC roots included. Arguments follow name, result type, argument types, vararg count and calling convention.
"""
function foreign_outcome(statement::Expr)::Outcome.Type
    name = foreign_name(statement.args[1])
    effects = isnothing(name) ? nothing : get(FOREIGN_EFFECTS, name, nothing)
    isnothing(effects) && return Outcome.Open(Operand.Type[Operand.Value(value) for value in statement.args[6:end]])
    count = length(statement.args[3]::Core.SimpleVector)
    return Outcome.Foreign(effects, Operand.Type[Operand.Value(value) for value in statement.args[6:(5 + count)]])
end

"""
Resolution of statement `statement` of `ir`: call or foreign call outcome; `nothing` for other statements. IR before
inlining holds no `:invoke` statement.
"""
function statement_outcome(ir::CC.IRCode, statement::Any, world::UInt)::Union{Nothing, Outcome.Type}
    statement isa Expr || return nothing
    statement.head === :call && return resolve(ir, Operand.Type[Operand.Value(value) for value in statement.args], world)
    statement.head === :foreigncall && return foreign_outcome(statement)
    return nothing
end
