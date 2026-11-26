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
Effects of call that table knows (`engine.md`, Calls, steps 2 and 6), by argument position: arguments it writes and
reads through; `copies` of source elements into destination elements; `stores` of argument into destination elements;
arguments result points into; arguments whose elements result may be; and arguments result may point beneath
(`aliases`, doubt in code). Every argument from position `rest` on takes role of `rest`; 0 means none. Writes take
`write_kind`; memory write takes kind of its path (`engine.md`, Effect kinds). `outside`: result is unknown object
without doubt, such as current task.
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
    write_kind::EffectKind.T = EffectKind.memory
    outside::Bool = false
end

include("foreign_gmp_mpfr.jl")
include("foreign_blas_lapack.jl")

"""
Table of libc and Julia runtime functions that Base call sites reach. Pointer argument stands for object it points into.
"""
const RUNTIME_EFFECTS = Dict{Symbol, CallEffects}(
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
    :jl_threadid => CallEffects(),
    # Current task: object outside caller places. Its RNG fields hold default RNG state.
    :jl_get_current_task => CallEffects(outside = true),
    :jl_rethrow => CallEffects(),
    :jl_rethrow_other => CallEffects(),
    :utf8proc_category => CallEffects(),
    Symbol("llvm.prefetch") => CallEffects(),
    :uv_cwd => CallEffects(writes = [1, 2], reads = [2]),
)

"""
MPFR and GMP functions that generated table leaves out (`gen/foreign/generate.jl`): variadic, or result points into
argument. Left open: `mpfr_set_emin`, `mpfr_set_emax`, `mpfr_clear_flags` (MPFR manual 5.13) and
`__gmp_set_memory_functions`, `__gmp_set_alloc_overflow_function` (GMP manual 4.7) write C global state.
"""
const HAND_EFFECTS = Dict{Symbol, CallEffects}(
    # Output pointer, template, formatted argument (MPFR manual 5.9). Output holds C heap string.
    :mpfr_asprintf => CallEffects(writes = [1], reads = [2, 3], rest = 3),
    # Frees C heap string, which no Julia object holds (MPFR manual 5.4).
    :mpfr_free_str => CallEffects(),
    # Limbs of `x` for writing; result points into `x` (GMP manual 5.16).
    :__gmpz_limbs_write => CallEffects(writes = [1], result = [1]),
    # Buffer, base, integer; result is buffer (GMP manual 5.4).
    :__gmpz_get_str => CallEffects(writes = [1], reads = [3], result = [1]),
    # Buffer, word count, order, size, endian, nails, integer; result is buffer (GMP manual 5.14).
    :__gmpz_export => CallEffects(writes = [1, 2], reads = [7], result = [1]),
)

"""
BLAS functions that generated table leaves out (`gen/foreign/blas_lapack.jl`): CBLAS dot products by `cblas.h` of
Reference-LAPACK (`const` pointer read), and `?axpby`, which OpenBLAS and MKL add (`y = alpha * x + beta * y`).
"""
const BLAS_HAND_EFFECTS = Dict{Symbol, CallEffects}(
    # Length, x, x stride, y, y stride; result is dot product.
    (name => CallEffects(reads = [2, 4]) for name in (:cblas_ddot64_, :cblas_sdot64_))...,
    # Length, x, x stride, y, y stride, output.
    (name => CallEffects(writes = [6], reads = [2, 4]) for name in (:cblas_zdotc_sub64_, :cblas_cdotc_sub64_, :cblas_zdotu_sub64_, :cblas_cdotu_sub64_))...,
    # Length, alpha, x, x stride, beta, y, y stride.
    (name => CallEffects(writes = [6], reads = [1, 2, 3, 4, 5, 6, 7]) for name in (:saxpby_64_, :daxpby_64_, :caxpby_64_, :zaxpby_64_))...,
)

"""
PCRE2 functions that Base regex code calls (`base/pcre.jl`), by PCRE2 API manual (`pcre2api`). Compile, match data,
match context and JIT stack results are new C objects, which no Julia object holds.
"""
const PCRE_EFFECTS = Dict{Symbol, CallEffects}(
    # Pattern, length, options, error code, error offset, compile context.
    :pcre2_compile_8 => CallEffects(writes = [4, 5], reads = [1]),
    # JIT compile adds machine code to compiled pattern.
    :pcre2_jit_compile_8 => CallEffects(writes = [1]),
    # Code, subject, length, offset, options, match data, match context: match uses JIT stack of context.
    :pcre2_match_8 => CallEffects(writes = [6, 7], reads = [1, 2]),
    :pcre2_match_data_create_from_pattern_8 => CallEffects(reads = [1]),
    :pcre2_get_ovector_count_8 => CallEffects(reads = [1]),
    :pcre2_get_ovector_pointer_8 => CallEffects(result = [1]),
    # Code, query, output.
    :pcre2_pattern_info_8 => CallEffects(writes = [3], reads = [1]),
    :pcre2_substring_number_from_name_8 => CallEffects(reads = [1, 2]),
    # Match data, group number, length output; copy also takes buffer before length.
    :pcre2_substring_length_bynumber_8 => CallEffects(writes = [3], reads = [1]),
    :pcre2_substring_copy_bynumber_8 => CallEffects(writes = [3, 4], reads = [1]),
    # Error code, buffer, buffer length.
    :pcre2_get_error_message_8 => CallEffects(writes = [2]),
    :pcre2_jit_stack_create_8 => CallEffects(),
    :pcre2_match_context_create_8 => CallEffects(),
    :pcre2_jit_stack_assign_8 => CallEffects(writes = [1]),
    :pcre2_match_data_free_8 => CallEffects(writes = [1]),
    :pcre2_code_free_8 => CallEffects(writes = [1]),
    :pcre2_jit_stack_free_8 => CallEffects(writes = [1]),
    :pcre2_match_context_free_8 => CallEffects(writes = [1]),
)

"""
Foreign call table: C functions corpus reaches, from Base call sites, Julia runtime source, MPFR, GMP and PCRE2.
Missing name stays open. No prefix rule: unknown `mpfr_` name stays open, since wrong entry gives false definite write.
"""
const FOREIGN_EFFECTS = merge(RUNTIME_EFFECTS, GENERATED_EFFECTS, HAND_EFFECTS, PCRE_EFFECTS)

"""
BLAS and LAPACK table: entry applies only to call into BLAS library (`blas_library`). Missing name stays open (`lbt_`
configuration of libblastrampoline).
"""
const BLAS_EFFECTS = merge(BLAS_LAPACK_EFFECTS, BLAS_HAND_EFFECTS)

"""
Whether shared library `library` is BLAS library: libblastrampoline, which LinearAlgebra calls, or OpenBLAS behind it.
Name may carry version and platform suffix (`libblastrampoline.so.5`, `libblastrampoline-5.dll`).
"""
blas_library(library::String)::Bool = occursin(r"^lib(blastrampoline|openblas64_)([.-]\d+)*(\.(so|dylib|dll)(\.\d+)*)?$", basename(library))

"""
Documented behavior of Base function (`engine.md`, Calls, step 6): `effects` on arguments; `callback` when function
also has form with callable first argument, which shifts positions; `breaches` lists argument position and Base types
that write there although contract only reads (`Iterators.Stateful`).
"""
struct BaseContract
    effects::CallEffects
    callback::Bool
    breaches::Vector{Pair{Int, Any}}
end

"""Base iterators whose iteration consumes them: `iterate` writes argument (`engine.md`, Calls, step 6)."""
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

"""
Log message (`AbstractLogger` interface, `handle_message`): message goes to logger sink, so logger takes IO write.
Contract keeps no record that logger may hold (`Test.TestLogger`).
"""
const LOG_MESSAGE = BaseContract(CallEffects(writes = [1], reads = [1, 2], rest = 2, write_kind = EffectKind.io), false, Pair{Int, Any}[])

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
    # Logger filters read; `@logmsg` calls them through `invokelatest` on logger of abstract type.
    Base.CoreLogging.shouldlog => QUERY, Base.CoreLogging.min_enabled_level => QUERY, Base.CoreLogging.catch_exceptions => QUERY,
    Base.CoreLogging.handle_message => LOG_MESSAGE,
)

"""
Call statement resolution (`engine.md`, Calls): `Builtin` or `Intrinsic` with operands after callee; `Foreign` call
table entry with C arguments; `Dispatch` to instances of matching methods with operands, callee first: one is static
call, more join; `Contract` effects with arguments and argument positions breach may write; `Open` dispatch with
operands, whose open types decide doubt (`engine.md`, Provenance); `Unresolved` call with operands that types cannot
resolve (unknown C function, unknown argument count), doubt in code; `Dead` when no method matches.
"""
@data Outcome begin
    Builtin(Any, Vector{Operand.Type})
    Intrinsic(Any, Vector{Operand.Type})
    Foreign(CallEffects, Vector{Operand.Type})
    Dispatch(Vector{Core.MethodInstance}, Vector{Operand.Type})
    Contract(CallEffects, Vector{Operand.Type}, Vector{Int})
    Open(Vector{Operand.Type})
    Unresolved(Vector{Operand.Type})
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
function call_types(ir::CC.IRCode, operands::AbstractVector{Operand.Type})::Vector{Any}
    types = Any[operand_type(ir, operand) for operand in operands if !is_rest(operand)]
    rests = Any[operand_type(ir, operand) for operand in operands if is_rest(operand)]
    isempty(rests) || push!(types, Vararg{Union{rests...}})
    return types
end

"""
Most methods run-time dispatch in package code joins (`engine.md`, Calls, step 5): compiler `max_methods`, never below.
Limit 8 reached 20 times more instances on Distances. Library code joins none (`join_limit`).
"""
const JOIN_LIMIT = 3

"""
Instances of methods call with argument `types` can reach in `world`, each specialized to call; `nothing` past
`limit` methods.
"""
function dispatch(types::AbstractVector{Any}, world::UInt, limit::Integer)::Union{Nothing, Vector{Core.MethodInstance}}
    matches = Base._methods_by_ftype(Tuple{types...}, limit, world)
    matches isa Vector || return nothing
    return Core.MethodInstance[CC.specialize_method(match::Core.MethodMatch) for match in matches]
end

"""
Resolution of call with `operands` (callee first) in `ir`: builtin, intrinsic, up to `limit` matching methods, else open.
Builtins that call operand (`invokelatest`, `_apply_iterate`, `finalizer`) resolve to call they make. Intrinsic operand
can be nested constant expression (`cglobal((:name, library))`), so operand types wait until dispatch. Builtin other
than `tuple` with `Rest` operands stays unresolved. Call of `FunctionStandIn` is open dispatch: it stands for any
function.
"""
function resolve(ir::CC.IRCode, operands::AbstractVector{Operand.Type}, world::UInt, limit::Integer)::Outcome.Type
    Base.require_one_based_indexing(operands)
    callee = @match first(operands) begin
        Operand.Value(value) => constant(ir, value)
        Operand.Rest(_) => return Outcome.Open(operands)
        Operand.Part(_, _) => nothing
    end
    if !isnothing(callee) && something(callee) isa Core.Builtin
        builtin = something(callee)
        builtin in (Core.invokelatest, Core._call_latest, Core.finalizer) && return resolve(ir, operands[2:end], world, limit)
        builtin in (Core.invoke_in_world, Core._call_in_world, Core._call_in_world_total) && return resolve(ir, operands[3:end], world, limit)
        builtin === Core.tuple || !any(is_rest, operands) || return Outcome.Unresolved(operands)
        builtin isa Core.IntrinsicFunction && return Outcome.Intrinsic(builtin, operands[2:end])
        builtin === Core._apply_iterate && return spread_call(ir, operands[3:end], world, limit)
        builtin === Core.invoke && return invoke_call(ir, operands, world)
        return Outcome.Builtin(builtin, operands[2:end])
    end
    stand_in_call(ir, callee, operands) && return Outcome.Open(operands)
    latest = latest_call(ir, callee, operands)
    isnothing(latest) || return resolve(ir, latest, world, limit)
    instances = dispatch(call_types(ir, operands), world, limit)
    isnothing(instances) && return contract_call(ir, callee, operands)
    # No matching method: call throws `MethodError`.
    return isempty(instances) ? Outcome.Dead() : Outcome.Dispatch(instances, operands)
end

"""
Operands of call that `Base.invokelatest_gr` with constant `GlobalRef` makes (`@invokelatest`), directly or with
keywords (`Core.kwcall`): binding read takes place of reference. `nothing` for other calls.
"""
function latest_call(ir::CC.IRCode, callee::Union{Nothing, Some{Any}}, operands::AbstractVector{Operand.Type})::Union{Nothing, Vector{Operand.Type}}
    Base.require_one_based_indexing(operands)
    isnothing(callee) && return nothing
    head = something(callee) === Core.kwcall ? 3 : 1
    length(operands) > head && is_constant(ir, operands[head], Base.invokelatest_gr) || return nothing
    reference = operand_constant(ir, operands[head + 1])
    (isnothing(reference) || !(something(reference) isa GlobalRef)) && return nothing
    return Operand.Type[operands[1:(head - 1)]; Operand.Value(something(reference)); operands[(head + 2):end]]
end

"""Whether `operand` holds constant `expected` in `ir`."""
function is_constant(ir::CC.IRCode, operand::Operand.Type, @nospecialize(expected::Any))::Bool
    found = operand_constant(ir, operand)
    return !isnothing(found) && something(found) === expected
end

"""Whether call of constant `callee` with `operands` calls `FunctionStandIn`, directly or with keywords (`Core.kwcall`)."""
function stand_in_call(ir::CC.IRCode, callee::Union{Nothing, Some{Any}}, operands::AbstractVector{Operand.Type})::Bool
    Base.require_one_based_indexing(operands)
    isnothing(callee) && return false
    something(callee) isa FunctionStandIn && return true
    something(callee) === Core.kwcall && length(operands) >= 3 || return false
    return operand_type(ir, operands[3]) === FunctionStandIn
end

"""
Resolution of call with `operands` (callee first) that dispatch leaves open: contract of constant `callee` (`Some`) in
`BASE_CONTRACTS`, else open. Callable first argument of function with callback form stays open: positions shift.
`Rest` operand needs vararg role at or before its position: any later role could take its elements. Keyword call
(`Core.kwcall`) puts keyword tuple last, in rest role (`keyword_role`).
"""
function contract_call(ir::CC.IRCode, callee::Union{Nothing, Some{Any}}, operands::AbstractVector{Operand.Type})::Outcome.Type
    Base.require_one_based_indexing(operands)
    keywords = !isnothing(callee) && something(callee) === Core.kwcall && length(operands) >= 3
    called = keywords ? operand_constant(ir, operands[3]) : callee
    contract = isnothing(called) ? nothing : get(BASE_CONTRACTS, something(called), nothing)
    isnothing(contract) && return Outcome.Open(operands)
    arguments = keywords ? Operand.Type[operands[4:end]; operands[2]] : operands[2:end]
    keywords && !keyword_role(ir, contract.effects, arguments) && return Outcome.Open(operands)
    spread = findfirst(is_rest, arguments)
    isnothing(spread) || 0 < contract.effects.rest <= spread || return Outcome.Unresolved(operands)
    types = Any[operand_type(ir, argument) for argument in arguments]
    contract.callback && !isempty(types) && typeintersect(first(types), Base.Callable) !== Union{} && return Outcome.Open(operands)
    admits(position::Integer, @nospecialize(type::Any))::Bool = any(index -> typeintersect(types[index], type) !== Union{}, role(contract.effects, position, length(types)))
    return Outcome.Contract(contract.effects, arguments, Int[position for (position, type) in contract.breaches if admits(position, type)])
end

"""
Whether keyword tuple, last of `arguments`, falls in rest role of `effects` that reads only, and holds no callable:
keyword callable (`by`) runs as callback.
"""
function keyword_role(ir::CC.IRCode, effects::CallEffects, arguments::AbstractVector{Operand.Type})::Bool
    rest = effects.rest
    0 < rest <= length(arguments) && rest in effects.reads || return false
    any(roles -> rest in roles, (effects.writes, effects.result, effects.elements, effects.aliases)) && return false
    any(pair -> rest in pair, [effects.stores; effects.copies]) && return false
    values = keyword_types(operand_type(ir, last(arguments)))
    return !isnothing(values) && all(value -> typeintersect(value, Base.Callable) === Union{}, values)
end

"""
Types that values of keyword tuple of `type` can take: field types of upper bound of its value tuple
(`NamedTuple{(:a,), <:Tuple{Tuple{Any}}}`); `nothing` when bound has no fixed fields.
"""
function keyword_types(@nospecialize(type::Any))::Union{Nothing, Vector{Any}}
    body = Base.unwrap_unionall(type)
    body isa DataType || return nothing
    body.name === Base.typename(NamedTuple) || return nothing
    values = last(body.parameters)
    values isa TypeVar && (values = values.ub)
    values isa DataType || return nothing
    values <: Tuple && !Base.isvatuple(values) || return nothing
    return collect(Any, fieldtypes(values))
end

"""Positions among `count` arguments that take role of `position` in `effects`: from `rest` on, all; past end, none."""
role(effects::CallEffects, position::Integer, count::Integer)::UnitRange{Int} = position == effects.rest ? (position:count) : (position:min(position, count))

"""
Resolution of `_apply_iterate` call: callee and spread `arguments` become operands. Tuple of known length gives `Part`
per position until first `Rest`; tuple or array of unknown length gives `Rest`. Other collections run `iterate`
methods, so call stays unresolved.
"""
function spread_call(ir::CC.IRCode, arguments::AbstractVector{Operand.Type}, world::UInt, limit::Integer)::Outcome.Type
    Base.require_one_based_indexing(arguments)
    operands = Operand.Type[first(arguments)]
    for argument in arguments[2:end]
        value = @match argument begin
            Operand.Value(value) => value
            _ => return Outcome.Unresolved(arguments)
        end
        type = value_type(ir, value)
        if definite_tuple(type) && !any(is_rest, operands)
            append!(operands, Operand.Type[Operand.Part(value, position) for position in 1:fieldcount(type)])
        elseif type isa DataType && type <: Union{Tuple, Array}
            push!(operands, Operand.Rest(value))
        else
            return Outcome.Unresolved(arguments)
        end
    end
    return resolve(ir, operands, world, limit)
end

"""
Resolution of `Core.invoke(f, T, args...)`: method `T` selects, specialized to argument types. Selector that is not
constant (`Tuple{typeof(x)}`) can select any method of `f`: contract of `f` covers them all, else call is unresolved.
"""
function invoke_call(ir::CC.IRCode, operands::AbstractVector{Operand.Type}, world::UInt)::Outcome.Type
    Base.require_one_based_indexing(operands)
    called = Operand.Type[operands[2]; operands[4:end]]
    types = Any[operand_type(ir, operand) for operand in called]
    selector = operand_constant(ir, operands[3])
    if isnothing(selector)
        callee = operand_constant(ir, operands[2])
        isnothing(callee) && return Outcome.Unresolved(called)
        return haskey(BASE_CONTRACTS, something(callee)) ? contract_call(ir, callee, called) : Outcome.Unresolved(called)
    end
    match = Base._which(Tuple{types[1], something(selector).parameters...}; world, raise = false)
    isnothing(match) && return Outcome.Unresolved(called)
    signature = typeintersect(Tuple{types...}, match.method.sig)
    signature === Union{} && return Outcome.Dead()
    return Outcome.Dispatch([CC.specialize_method(match.method, signature, match.sparams)], called)
end

"""Name of C function that foreign call `target` names: symbol or string, alone or first of library tuple."""
function foreign_name(@nospecialize(target::Any))::Union{Nothing, Symbol}
    target isa QuoteNode && return foreign_name(target.value)
    target isa Expr && target.head === :tuple && !isempty(target.args) && return foreign_name(first(target.args))
    target isa Tuple && !isempty(target) && return foreign_name(first(target))
    target isa Symbol && return target
    target isa String && return Symbol(target)
    return nothing
end

"""
Shared library that foreign call `target` names: string, or constant global that holds one. No library, or library
that only run time fixes, gives `nothing`.
"""
function foreign_library(@nospecialize(target::Any))::Union{Nothing, String}
    target isa QuoteNode && return foreign_library(target.value)
    library = target isa Expr && target.head === :tuple && length(target.args) == 2 ? target.args[2] : target isa Tuple && length(target) == 2 ? target[2] : nothing
    library isa QuoteNode && (library = library.value)
    library isa GlobalRef && isconst(library) && (library = getglobal(library.mod, library.name))
    return library isa String ? library : nothing
end

"""Table entry of foreign call `target`, or `nothing`. BLAS name in other library stays open: same name, other contract."""
function foreign_effects(@nospecialize(target::Any))::Union{Nothing, CallEffects}
    name = foreign_name(target)
    isnothing(name) && return nothing
    haskey(BLAS_EFFECTS, name) || return get(FOREIGN_EFFECTS, name, nothing)
    library = foreign_library(target)
    return !isnothing(library) && blas_library(library) ? BLAS_EFFECTS[name] : nothing
end

"""Highest argument position entry `effects` names; rest position counts none, since vararg may be empty."""
function arity(effects::CallEffects)::Int
    pairs = [effects.copies; effects.stores]
    return maximum([effects.writes; effects.reads; effects.result; effects.elements; effects.aliases; first.(pairs); last.(pairs)]; init = 0)
end

"""
Resolution of foreign call `statement`: table entry with C arguments when table knows target and call passes each
argument entry names; else unresolved on every operand, GC roots included. Arguments follow target, result type,
argument types, vararg count and calling convention.
"""
function foreign_outcome(statement::Expr)::Outcome.Type
    effects = foreign_effects(statement.args[1])
    count = length(statement.args[3]::Core.SimpleVector)
    (isnothing(effects) || arity(effects) > count) && return Outcome.Unresolved(Operand.Type[Operand.Value(value) for value in statement.args[6:end]])
    return Outcome.Foreign(effects, Operand.Type[Operand.Value(value) for value in statement.args[6:(5 + count)]])
end

"""
Resolution of statement `statement` of `ir`: call or foreign call outcome; `nothing` for other statements. IR before
inlining holds no `:invoke` statement.
"""
function statement_outcome(ir::CC.IRCode, @nospecialize(statement::Any), world::UInt, limit::Integer)::Union{Nothing, Outcome.Type}
    statement isa Expr || return nothing
    statement.head === :call && return resolve(ir, Operand.Type[Operand.Value(value) for value in statement.args], world, limit)
    statement.head === :foreigncall && return foreign_outcome(statement)
    return nothing
end

"""Constant value of call `operand` in `ir`; `nothing` when not constant."""
operand_constant(ir::CC.IRCode, operand::Operand.Type)::Union{Nothing, Some{Any}} = @match operand begin
    Operand.Value(value) => constant(ir, value)
    _ => nothing
end

"""
Release balance primitive (`engine.md`, Release balance): hold `change` (`nothing` for `trylock`: blind spot), operand
position of resource (0: call result), resource kind, and whether flow skips callee body: engine never reads lock or
semaphore bodies.
"""
struct Primitive
    change::Union{Nothing, Int}
    operand::Int
    resource::Resource.T
    skips::Bool
end

"""
Primitive that call with `operands` (callee first) and result of `type` makes in `ir`, or `nothing`. Keyword call
(`Core.kwcall`) names callee third. Argument types pick resource: lock, `Semaphore`, `Condition`, `IOStream`.
`wait(::Condition)` releases lock and takes it again.
"""
function primitive(ir::CC.IRCode, operands::AbstractVector{Operand.Type}, @nospecialize(type::Any))::Union{Nothing, Primitive}
    Base.require_one_based_indexing(operands)
    callee, first_argument = operand_constant(ir, operands[1]), 2
    if !isnothing(callee) && something(callee) === Core.kwcall && length(operands) >= 3
        callee, first_argument = operand_constant(ir, operands[3]), 4
    end
    isnothing(callee) && return nothing
    arguments = @view(operands[first_argument:end])
    any(is_rest, arguments) && return nothing
    call = something(callee)
    if length(arguments) == 1
        resource = operand_type(ir, only(arguments))
        lock_call = resource <: Base.AbstractLock
        lock_call && call === lock && return Primitive(1, first_argument, Resource.lock, true)
        lock_call && call === unlock && return Primitive(-1, first_argument, Resource.lock, true)
        lock_call && call === trylock && return Primitive(nothing, first_argument, Resource.lock, true)
        slot_call = resource <: Base.Semaphore
        slot_call && call === Base.acquire && return Primitive(1, first_argument, Resource.lock, true)
        slot_call && call === Base.release && return Primitive(-1, first_argument, Resource.lock, true)
        call === wait && resource <: Base.GenericCondition && return Primitive(0, first_argument, Resource.lock, true)
        call === close && resource <: IOStream && return Primitive(-1, first_argument, Resource.file, false)
    end
    # Do-block form (`open(f, path)`) releases in its own `finally`.
    file_call = call === open && !isempty(arguments) && typeintersect(operand_type(ir, first(arguments)), Base.Callable) === Union{}
    file_call && CC.widenconst(type) <: IOStream && return Primitive(1, 0, Resource.file, false)
    return nothing
end
