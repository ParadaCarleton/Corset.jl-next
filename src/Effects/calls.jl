"""
Operand of call: IR `Value`; `Part` at position of tuple value that `_apply_iterate` spreads; or `Rest`: every element of
tuple or array value spread with unknown count. `Rest` operands come after all others.
"""
@data Operand begin
    Value(Any)
    Part(Any, Int)
    Rest(Any)
end

"""Whether `operand` stands for elements of unknown count (`Operand.Rest`)."""
is_rest(operand::Operand.Type)::Bool = @match operand begin
    Operand.Rest(_) => true
    _ => false
end

"""
Effects of call that table knows (`effects.md`, Calls, steps 2 and 6), by argument position: arguments it writes and
reads through; `copies` of source elements into destination elements; `stores` of argument into destination elements;
arguments result points into; arguments whose elements result may be; and arguments result may point beneath
(`aliases`, doubt in code). Every argument from position `rest` on takes role of `rest`; 0 means none.
"""
Base.@kwdef struct CallEffects
    writes::Vector{Int} = Int[]
    reads::Vector{Int} = Int[]
    copies::Vector{Pair{Int, Int}} = Pair{Int, Int}[]
    stores::Vector{Pair{Int, Int}} = Pair{Int, Int}[]
    result::Vector{Int} = Int[]
    elements::Vector{Int} = Int[]
    aliases::Vector{Int} = Int[]
    rest::Int = 0
end

"""
Foreign call table: C functions corpus reaches, from Base call sites and Julia runtime source. Pointer argument stands
for object it points into. Missing name stays open.
"""
const FOREIGN_EFFECTS = Dict{Symbol, CallEffects}(
    :memmove => CallEffects(writes = [1], reads = [2], copies = [1 => 2], result = [1]),
    :memcpy => CallEffects(writes = [1], reads = [2], copies = [1 => 2], result = [1]),
    :memset => CallEffects(writes = [1], result = [1]),
    :memcmp => CallEffects(reads = [1, 2]),
    :memchr => CallEffects(reads = [1], result = [1]),
    :memrchr => CallEffects(reads = [1], result = [1]),
    :strlen => CallEffects(reads = [1]),
    # Destination memory, its pointer, source memory, its pointer, count.
    :jl_genericmemory_copyto => CallEffects(writes = [1, 2], reads = [3, 4], copies = [1 => 3, 2 => 4]),
    :jl_object_id => CallEffects(reads = [1]),
    # Pointer of object, or object at pointer (`unsafe_pointer_to_objref`).
    :jl_value_ptr => CallEffects(result = [1]),
    :jl_string_ptr => CallEffects(result = [1]),
    :jl_symbol_name => CallEffects(result = [1]),
    :jl_symbol_n => CallEffects(reads = [1]),
    # `String` and type results point to no object effects track.
    :jl_alloc_string => CallEffects(),
    :jl_pchar_to_string => CallEffects(reads = [1]),
    # Memory shares bytes of string; string takes bytes of memory, which it empties.
    :jl_string_to_genericmemory => CallEffects(result = [1]),
    :jl_genericmemory_to_string => CallEffects(writes = [1], reads = [1]),
    :jl_genericmemory_owner => CallEffects(result = [1]),
    # `IdDict` table: memory, key, value or default, flag pointer. Rehashed table counts as same memory.
    :jl_eqtable_get => CallEffects(reads = [1], result = [3], elements = [1]),
    :jl_eqtable_put => CallEffects(writes = [1, 4], reads = [1], stores = [1 => 2, 1 => 3], result = [1]),
    :jl_eqtable_pop => CallEffects(writes = [1, 4], reads = [1], result = [3], elements = [1]),
    :jl_eqtable_nextind => CallEffects(reads = [1]),
    :jl_idtable_rehash => CallEffects(reads = [1], result = [1]),
    :jl_idset_peek_bp => CallEffects(reads = [1, 2]),
    :jl_type_unionall => CallEffects(),
    :jl_types_equal => CallEffects(),
    :jl_has_typevar => CallEffects(),
    :jl_stored_inline => CallEffects(),
    :jl_islayout_inline => CallEffects(writes = [2, 3]),
    :jl_get_world_counter => CallEffects(),
    :jl_get_tls_world_age => CallEffects(),
    :jl_rethrow => CallEffects(),
    :jl_rethrow_other => CallEffects(),
    :utf8proc_category => CallEffects(),
    Symbol("llvm.prefetch") => CallEffects(),
    :uv_cwd => CallEffects(writes = [1, 2], reads = [2]),
)

"""
Documented behavior of Base function (`effects.md`, Calls, step 6): `effects` on arguments; `callback` when function
also has form with callable first argument, which shifts positions; `breaches` lists argument position and Base types
that write there although contract only reads (`Iterators.Stateful`).
"""
struct BaseContract
    effects::CallEffects
    callback::Bool
    breaches::Vector{Pair{Int, Any}}
end

"""Base iterators whose iteration consumes them: `iterate` writes argument (`effects.md`, Calls, step 6)."""
const CONSUMED = Union{Iterators.Stateful, Channel, Base.EachLine}

"""
Query: no `!`, so no argument write (Julia style guide, "Append `!` to names of functions that modify their
arguments"). Reads every argument; result is new value. Aliasing every query result cost JSON 3 times `effects` time.
"""
const QUERY = BaseContract(CallEffects(reads = [1], rest = 1), false, Pair{Int, Any}[])

"""
Alias query: like `QUERY`, but result may point beneath arguments: `convert` docstring says so; `max`, `conj`, `float`
can return argument; `keys`, `adjoint` wrap it.
"""
const ALIAS_QUERY = BaseContract(CallEffects(reads = [1], aliases = [1], rest = 1), false, Pair{Int, Any}[])

"""Element query: reads collection; result may be its element or point beneath it, never into indices (`getindex`)."""
const ELEMENT_QUERY = BaseContract(CallEffects(reads = [1], elements = [1], aliases = [1]), false, Pair{Int, Any}[])

"""Iteration: like `ELEMENT_QUERY`; consumed iterator in first argument gets `possible` write (`isempty` docstring)."""
const ITERATION = BaseContract(CallEffects(reads = [1], elements = [1], aliases = [1], rest = 1), false, Pair{Int, Any}[1 => CONSUMED])

"""Write to first argument, which call returns (`resize!`, `empty!`, `delete!`)."""
const RETURNED_WRITE = BaseContract(CallEffects(writes = [1], result = [1]), false, Pair{Int, Any}[])

"""Store of value at position 2 into first argument, which call returns (`setindex!`, `fill!`)."""
const VALUE_STORE = BaseContract(CallEffects(writes = [1], stores = [1 => 2], result = [1]), false, Pair{Int, Any}[])

"""Store of every argument after first into first argument, which call returns (`push!`)."""
const ITEMS_STORE = BaseContract(CallEffects(writes = [1], stores = [1 => 2], result = [1], rest = 2), false, Pair{Int, Any}[])

"""Copy of elements of every argument after first into first argument, which call returns (`append!`)."""
const ITEMS_COPY = BaseContract(CallEffects(writes = [1], reads = [2], copies = [1 => 2], result = [1], rest = 2), false, Pair{Int, Any}[2 => CONSUMED])

"""Base functions with `QUERY` contract: comparison, size queries, predicates, arithmetic."""
const QUERIES = (
    ==, !=, isequal, isless, <, <=, >, >=, cmp, hash, haskey, length, size, axes, ndims, eltype, keytype, valtype,
    firstindex, lastindex, +, -, *, /, \, ^, //, div, rem, mod, fld, cld, abs, abs2, sign, sqrt, cbrt, exp, log, log2,
    log10, imag, zero, one, oneunit, iszero, isone, !, ~, &, |, xor, <<, >>, >>>, isnan, isinf, isfinite, round, floor,
    ceil, trunc,
)

"""Base functions with `ALIAS_QUERY` contract: result can be argument, its field, or wrapper around it."""
const ALIAS_QUERIES = (convert, getproperty, keys, values, pairs, eachindex, max, min, real, conj, float, adjoint, transpose)

"""Copy of source elements into destination, which call returns; 5-argument form takes source third (`copyto!`)."""
const RANGE_COPY = BaseContract(CallEffects(writes = [1], reads = [2, 3], copies = [1 => 2, 1 => 3], result = [1]), false, Pair{Int, Any}[2 => CONSUMED])

"""
Base contract table: interface functions corpus calls through open dispatch, by documented behavior only. Functions
with own effect kind (IO, locks, random numbers) and functions that call callbacks wait for PR 3 and callback records.
"""
const BASE_CONTRACTS = IdDict{Any, BaseContract}(
    (query => QUERY for query in QUERIES)...,
    (query => ALIAS_QUERY for query in ALIAS_QUERIES)...,
    getindex => ELEMENT_QUERY, first => ITERATION, only => ITERATION, isempty => ITERATION,
    iterate => ITERATION, Base.indexed_iterate => ITERATION,
    # `in(item, collection)` iterates its second argument.
    in => BaseContract(CallEffects(reads = [1], rest = 1), false, Pair{Int, Any}[2 => CONSUMED]),
    # View and lazy wrapper: result lies within array; writes through it write array.
    view => BaseContract(CallEffects(result = [1], aliases = [2], rest = 2), false, Pair{Int, Any}[]),
    similar => BaseContract(CallEffects(), false, Pair{Int, Any}[]),
    setindex! => VALUE_STORE, fill! => VALUE_STORE, push! => ITEMS_STORE, pushfirst! => ITEMS_STORE,
    append! => ITEMS_COPY, prepend! => ITEMS_COPY,
    resize! => RETURNED_WRITE, sizehint! => RETURNED_WRITE, empty! => RETURNED_WRITE, delete! => RETURNED_WRITE,
    deleteat! => RETURNED_WRITE, copyto! => RANGE_COPY, unsafe_copyto! => RANGE_COPY,
    insert! => BaseContract(CallEffects(writes = [1], stores = [1 => 3], result = [1]), false, Pair{Int, Any}[]),
    pop! => BaseContract(CallEffects(writes = [1], elements = [1], aliases = [3]), false, Pair{Int, Any}[]),
    popfirst! => BaseContract(CallEffects(writes = [1], elements = [1]), false, Pair{Int, Any}[]),
    get => BaseContract(CallEffects(reads = [1, 2], elements = [1], aliases = [3]), true, Pair{Int, Any}[]),
    get! => BaseContract(CallEffects(writes = [1], reads = [1], stores = [1 => 2, 1 => 3], elements = [1], aliases = [3]), true, Pair{Int, Any}[]),
    merge! => BaseContract(CallEffects(writes = [1], reads = [2], copies = [1 => 2], result = [1], rest = 2), true, Pair{Int, Any}[]),
)

"""
Call statement resolution (`effects.md`, Calls): `Builtin` or `Intrinsic` with operands after callee; `Foreign` call
table entry with C arguments; `Dispatch` to instances of matching methods with operands, callee first: one is static
call, more join; `Contract` effects with arguments and argument positions breach may write; `Open` call with operands;
`Dead` when no method matches.
"""
@data Outcome begin
    Builtin(Any, Vector{Operand.Type})
    Intrinsic(Any, Vector{Operand.Type})
    Foreign(CallEffects, Vector{Operand.Type})
    Dispatch(Vector{Core.MethodInstance}, Vector{Operand.Type})
    Contract(CallEffects, Vector{Operand.Type}, Vector{Int})
    Open(Vector{Operand.Type})
    Dead()
end

"""Type of `operand` in `ir`: element type for `Rest`."""
function operand_type(ir::CC.IRCode, operand::Operand.Type)::Any
    return @match operand begin
        Operand.Value(value) => value_type(ir, value)
        Operand.Part(value, position) => fieldtype(value_type(ir, value), position)
        Operand.Rest(value) => eltype(value_type(ir, value))
    end
end

"""Argument types of call with `operands` for dispatch: `Rest` operands join into one trailing `Vararg`."""
function call_types(ir::CC.IRCode, operands::Vector{Operand.Type})::Vector{Any}
    types = Any[operand_type(ir, operand) for operand in operands if !is_rest(operand)]
    rests = Any[operand_type(ir, operand) for operand in operands if is_rest(operand)]
    isempty(rests) || push!(types, Vararg{Union{rests...}})
    return types
end

"""
Most methods run-time dispatch in package code joins (`effects.md`, Calls, step 5): compiler `max_methods`, never below.
Limit 8 reached 20 times more instances on Distances. Library code joins none (`join_limit`).
"""
const JOIN_LIMIT = 3

"""
Instances of methods call with argument `types` can reach in `world`, each specialized to call; `nothing` past
`limit` methods.
"""
function dispatch(types::Vector{Any}, world::UInt, limit::Int)::Union{Nothing, Vector{Core.MethodInstance}}
    matches = Base._methods_by_ftype(Tuple{types...}, limit, world)
    matches isa Vector || return nothing
    return Core.MethodInstance[CC.specialize_method(match::Core.MethodMatch) for match in matches]
end

"""
Resolution of call with `operands` (callee first) in `ir`: builtin, intrinsic, up to `limit` matching methods, else open.
Builtins that call operand (`invokelatest`, `_apply_iterate`, `finalizer`) resolve to call they make. Intrinsic operand
can be nested constant expression (`cglobal((:name, library))`), so operand types wait until dispatch. Builtin other
than `tuple` with `Rest` operands stays open.
"""
function resolve(ir::CC.IRCode, operands::Vector{Operand.Type}, world::UInt, limit::Int)::Outcome.Type
    callee = @match first(operands) begin
        Operand.Value(value) => constant(ir, value)
        Operand.Rest(_) => return Outcome.Open(operands)
        Operand.Part(_, _) => nothing
    end
    if !isnothing(callee) && something(callee) isa Core.Builtin
        builtin = something(callee)
        builtin in (Core.invokelatest, Core._call_latest, Core.finalizer) && return resolve(ir, operands[2:end], world, limit)
        builtin in (Core.invoke_in_world, Core._call_in_world, Core._call_in_world_total) && return resolve(ir, operands[3:end], world, limit)
        builtin === Core.tuple || !any(is_rest, operands) || return Outcome.Open(operands)
        builtin isa Core.IntrinsicFunction && return Outcome.Intrinsic(builtin, operands[2:end])
        builtin === Core._apply_iterate && return spread_call(ir, operands[3:end], world, limit)
        builtin === Core.invoke && return invoke_call(ir, operands, world)
        return Outcome.Builtin(builtin, operands[2:end])
    end
    instances = dispatch(call_types(ir, operands), world, limit)
    isnothing(instances) && return contract_call(ir, callee, operands)
    # No matching method: call throws `MethodError`.
    return isempty(instances) ? Outcome.Dead() : Outcome.Dispatch(instances, operands)
end

"""
Resolution of call with `operands` (callee first) that dispatch leaves open: contract of constant `callee` (`Some`) in
`BASE_CONTRACTS`, else open. Callable first argument of function with callback form stays open: positions shift.
`Rest` operand needs vararg role at or before its position: any later role could take its elements.
"""
function contract_call(ir::CC.IRCode, callee::Union{Nothing, Some{Any}}, operands::Vector{Operand.Type})::Outcome.Type
    contract = isnothing(callee) ? nothing : get(BASE_CONTRACTS, something(callee), nothing)
    isnothing(contract) && return Outcome.Open(operands)
    arguments = operands[2:end]
    spread = findfirst(is_rest, arguments)
    isnothing(spread) || 0 < contract.effects.rest <= spread || return Outcome.Open(operands)
    types = Any[operand_type(ir, argument) for argument in arguments]
    contract.callback && !isempty(types) && typeintersect(first(types), Base.Callable) !== Union{} && return Outcome.Open(operands)
    admits(position::Int, type::Any)::Bool = any(index -> typeintersect(types[index], type) !== Union{}, role(contract.effects, position, length(types)))
    return Outcome.Contract(contract.effects, arguments, Int[position for (position, type) in contract.breaches if admits(position, type)])
end

"""Positions among `count` arguments that take role of `position` in `effects`: from `rest` on, all; past end, none."""
role(effects::CallEffects, position::Int, count::Int)::UnitRange{Int} = position == effects.rest ? (position:count) : (position:min(position, count))

"""
Resolution of `_apply_iterate` call: callee and spread `arguments` become operands. Tuple of known length gives `Part`
per position until first `Rest`; tuple or array of unknown length gives `Rest`. Other collections run `iterate`
methods, so call stays open.
"""
function spread_call(ir::CC.IRCode, arguments::Vector{Operand.Type}, world::UInt, limit::Int)::Outcome.Type
    operands = Operand.Type[first(arguments)]
    for argument in arguments[2:end]
        value = @match argument begin
            Operand.Value(value) => value
            _ => return Outcome.Open(arguments)
        end
        type = value_type(ir, value)
        if definite_tuple(type) && !any(is_rest, operands)
            append!(operands, (Operand.Part(value, position) for position in 1:fieldcount(type)))
        elseif type isa DataType && type <: Union{Tuple, Array}
            push!(operands, Operand.Rest(value))
        else
            return Outcome.Open(arguments)
        end
    end
    return resolve(ir, operands, world, limit)
end

"""Resolution of `Core.invoke(f, T, args...)`: method `T` selects, specialized to argument types; open without it."""
function invoke_call(ir::CC.IRCode, operands::Vector{Operand.Type}, world::UInt)::Outcome.Type
    called = Operand.Type[operands[2]; operands[4:end]]
    types = Any[operand_type(ir, operand) for operand in called]
    selector = @match operands[3] begin
        Operand.Value(value) => constant(ir, value)
        _ => nothing
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
function statement_outcome(ir::CC.IRCode, statement::Any, world::UInt, limit::Int)::Union{Nothing, Outcome.Type}
    statement isa Expr || return nothing
    statement.head === :call && return resolve(ir, Operand.Type[Operand.Value(value) for value in statement.args], world, limit)
    statement.head === :foreigncall && return foreign_outcome(statement)
    return nothing
end
