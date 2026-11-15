"""
`inference` stage scan for weak values that widen input types (`type-disruption`, `intermediate-widening`).

Weak value: number literal, constant, call of weak values only (`sqrt(2)`), variable assigned one, or Base number type
name. Inputs combine by normal promotion; weak value must not change result type. Kinds follow NumPy 2: integer weak
value takes either input kind, float weak value only float kind.
Scan converts each weak value that meets input to stand-in type in copy of lowered code, and native inference runs on
it. Rounds repeat until no new weak value meets input, so `x * 2.0 + 1.0` converts both. Then each weak value stays
unconverted alone: changed type of returned or stored value is escape; changed number intermediate only is widening.
"""
module Widening

using ..Facts: Weak, Exit
using ..StandIns: StandIns, FloatStandIn, IntStandIn

const CC = Core.Compiler

"""
Most rounds of meeting search; each round adds weak values that meet input once earlier ones convert. Nested
polynomial `a + x * (b + x * c)` needs one round per level, so bound only stops runaway search.
"""
const ROUNDS = 32

"""Most methods one call may match for meeting test; beyond it, result counts as unknown."""
const MATCHES = 4

"""
Weak value at statement `index`: call argument `position` (1 is callee), or 0 for right side of variable assignment.
`value` is number, or number type for name. `replacement` takes its place: `value` converted to `stand_in`, or
`stand_in` itself for name. `site` is first statement where weak value meets input.
"""
struct Origin
    index::Int
    position::Int
    kind::Weak.T
    value::Any
    replacement::Any
    site::Int
    stand_in::Type
end

"""
Effect of leaving `origin` unconverted while other weak values convert: type changes at statement `at`, as `exit` says.
`found` is type there with `origin` unconverted; `expected` is type with every weak value converted.
"""
struct Change
    origin::Origin
    exit::Exit.T
    at::Int
    found::Type
    expected::Type
end

"""Number stand-in that `type` holds, parameters and union members included; `nothing` when none."""
function number_stand_in(type::Any)::Union{Nothing, Type}
    type in StandIns.NUMBERS && return type
    type isa Union && return something(number_stand_in(type.a), number_stand_in(type.b), Some(nothing))
    type isa UnionAll && return number_stand_in(type.body)
    type isa DataType || return nothing
    for parameter in type.parameters
        found = number_stand_in(parameter)
        isnothing(found) || return found
    end
    return nothing
end

"""Widest Base type of stand-in kind: `Float64` for float, `Int` for integer. Meeting test swaps input to it."""
widest(stand_in::Type)::Type = stand_in === FloatStandIn ? Float64 : Int

"""
`type` with `stand_in` replaced by `widest` type of its kind, parameters included; `nothing` when parameter bound
rejects that type.
"""
function swapped(type::Any, stand_in::Type)::Any
    type === stand_in && return widest(stand_in)
    type isa Union && return Union{swapped(type.a, stand_in), swapped(type.b, stand_in)}
    (type isa DataType && !isempty(type.parameters)) || return type
    return try
        type.name.wrapper{Any[swapped(parameter, stand_in) for parameter in type.parameters]...}
    catch error
        error isa TypeError || rethrow()
        nothing
    end
end

"""Argument after hoisted reads: lowering reads globals and variables into statements (`%3 = Main.HALF`)."""
function resolved(code::Core.CodeInfo, argument::Any)::Any
    while argument isa Core.SSAValue
        statement = code.code[argument.id]
        statement isa Union{GlobalRef, Core.SlotNumber} || break
        argument = statement
    end
    return argument
end

"""Whether `value` is weak data: number other than `Bool`, or tuple of them (`evalpoly` coefficients)."""
function weak_data(value::Any)::Bool
    value isa Number && return !(value isa Bool)
    (value isa Tuple && !isempty(value)) || return false
    for element in value
        (element isa Number && !(element isa Bool)) || return false
    end
    return true
end

"""
Weak value `argument` of `code` holds, with its kind: number literal, constant, or call of weak values that inference
folds (`sqrt(2)`, `2π`, `(1.0, 2.0)`); concrete Base number type for name. `nothing` for other argument.
"""
function weak(code::Core.CodeInfo, argument::Any)::Union{Nothing, Tuple{Any, Weak.T}}
    argument = resolved(code, argument)
    argument isa Number && !(argument isa Bool) && return argument, Weak.literal
    if argument isa GlobalRef
        (isdefined(argument.mod, argument.name) && isconst(argument.mod, argument.name)) || return nothing
        value = getglobal(argument.mod, argument.name)
        weak_data(value) && return value, Weak.constant
        # Package number type defines its own promotion.
        value isa DataType && value <: Number && isconcretetype(value) && parentmodule(value) === Core && return value, Weak.name
    elseif argument isa Core.SSAValue
        call, type = code.code[argument.id], code.ssavaluetypes[argument.id]
        (call isa Expr && call.head === :call && length(call.args) >= 2) || return nothing
        (type isa Core.Const && weak_data(type.val)) || return nothing
        parts = [weak(code, part) for part in call.args[2:end]]
        any(isnothing, parts) && return nothing
        # Tuple of literals (`@evalpoly` coefficients) reads as literal in source.
        tupled = resolved(code, call.args[1]) == GlobalRef(Core, :tuple) && all(part -> last(something(part)) == Weak.literal, parts)
        return type.val, tupled ? Weak.literal : Weak.constant
    end
    return nothing
end

"""Right side of assignment `statement`; statement itself otherwise."""
assigned(statement::Any)::Any = statement isa Expr && statement.head === :(=) ? statement.args[2] : statement

"""Weak values each variable of `code` takes from assignment, as (statement, value) pairs: `s = 0` makes `s` weak."""
function variable_origins(code::Core.CodeInfo)::Dict{Int, Vector{Tuple{Int, Any}}}
    found = Dict{Int, Vector{Tuple{Int, Any}}}()
    for (index, statement) in enumerate(code.code)
        statement isa Expr && statement.head === :(=) && statement.args[1] isa Core.SlotNumber || continue
        value = weak(code, statement.args[2])
        isnothing(value) || value[2] == Weak.name || push!(get!(found, statement.args[1].id, Tuple{Int, Any}[]), (index, value[1]))
    end
    return found
end

"""
Value that replaces weak `value` for `stand_in`, by NumPy 2 kinds: integer converts to either stand-in, other real
number to float stand-in only; tuple converts each element. `nothing` when kind or range rejects conversion.
"""
function replacement(value::Any, stand_in::Type)::Union{Nothing, Some{Any}}
    if value isa Tuple
        elements = Any[]
        for element in value
            swap = replacement(element, stand_in)
            isnothing(swap) && return nothing
            push!(elements, something(swap))
        end
        return Some{Any}(Tuple(elements))
    end
    (value isa Integer || (stand_in === FloatStandIn && value isa Real)) || return nothing
    return try
        Some{Any}(convert(stand_in, value))
    catch error
        # Integer beyond `Int32` range needs wider type.
        error isa InexactError || rethrow()
        nothing
    end
end

"""
Whether Base number type `name` widens input of `stand_in` kind and keeps kind: `Float64(x)` on float input.
Conversion to narrower type (`UInt8(d)`) or other kind (`UInt64(n)` on signed input) changes input on purpose.
"""
function renames(name::Type, stand_in::Type)::Bool
    model = StandIns.model(stand_in)
    return name !== model && name <: (stand_in === FloatStandIn ? AbstractFloat : Signed) && promote_type(name, model) === name
end

"""Whether position `position` of call to `callee` takes type name that converts: callee, `convert(T, x)`, `T.(x)`."""
conversion(callee::Any, position::Int)::Bool = position == 1 || (position == 2 && callee in (convert, Base.Broadcast.broadcasted))

"""
Result type of call with argument types `types`, callee first, over at most `MATCHES` methods; `Any` when unknown.
Adds instances it infers to compiler `edges`.
"""
function call_result!(edges::Vector{Any}, types::Vector{Any})::Type
    matches = Base._methods_by_ftype(Tuple{types...}, MATCHES, Base.get_world_counter())
    (matches isa Vector && !isempty(matches)) || return Any
    interpreter, result = CC.NativeInterpreter(), Union{}
    for match in matches
        instance = CC.specialize_method(match::Core.MethodMatch)
        push!(edges, instance)
        result = Union{result, something(CC.typeinf_type(interpreter, instance), Any)}
    end
    return result
end

"""Whether call result type `type` tells meeting test something: call neither throws nor infers `Any`."""
known(type::Type)::Bool = type !== Union{} && type !== Any

"""Argument `types` with type of each of `positions` replaced by its converted type in `swaps`."""
function with_swaps(types::Vector{Any}, swaps::Dict{Int, Any}, positions::Any)::Vector{Any}
    converted = copy(types)
    for position in positions
        converted[position] = swaps[position]
    end
    return converted
end

"""
Add to `found` weak values of typed `code` that meet input, except `dropped` keys; whether any is new. Call meets input when argument holds
number stand-in, weak value converts, and with weak values converted, result type changes and follows input type: swap
of input to `widest` type changes it. So `fill(0, n)` does not meet size `n`. Name that converts input meets it at once.
Builtins (`getfield(t, 2)`) take no number data. Adds instances meeting test infers to compiler `edges`.
"""
function meetings!(found::Dict{Tuple{Int, Int}, Origin}, dropped::Set{Tuple{Int, Int}}, edges::Vector{Any}, code::Core.CodeInfo, parameters::Vector{CC.VarState})::Bool
    variables = variable_origins(code)
    count = length(found)
    for (index, statement) in enumerate(code.code)
        call = assigned(statement)
        call isa Expr && call.head === :call || continue
        callee = CC.argextype(call.args[1], code, parameters)
        callee = callee isa Core.Const ? callee.val : nothing
        callee isa Core.Builtin && continue
        types = Any[CC.widenconst(CC.argextype(argument, code, parameters)) for argument in call.args]
        values = Union{Nothing, Tuple{Any, Weak.T}}[weak(code, argument) for argument in call.args]
        held = Union{Nothing, Vector{Tuple{Int, Any}}}[(read = resolved(code, argument); read isa Core.SlotNumber ? get(variables, read.id, nothing) : nothing) for argument in call.args]
        inputs = [number_stand_in(types[position]) for position in eachindex(types) if isnothing(values[position]) && isnothing(held[position])]
        FloatStandIn in inputs || IntStandIn in inputs || continue
        stand_in = FloatStandIn in inputs ? FloatStandIn : IntStandIn
        # Origins by call position, and type each position takes once its weak value converts.
        new, swaps, named = Pair{Int, Origin}[], Dict{Int, Any}(), false
        for position in eachindex(call.args)
            if !isnothing(values[position])
                value, kind = something(values[position])
                if kind == Weak.name
                    (conversion(callee, position) && renames(value, stand_in)) || continue
                    push!(new, position => Origin(index, position, kind, value, stand_in, index, stand_in))
                    swaps[position], named = Type{stand_in}, true
                else
                    swap = replacement(value, stand_in)
                    position > 1 && !isnothing(swap) || continue
                    push!(new, position => Origin(index, position, kind, value, something(swap), index, stand_in))
                    swaps[position] = typeof(something(swap))
                end
            elseif !isnothing(held[position])
                for (assignment, value) in something(held[position])
                    swap = replacement(value, stand_in)
                    isnothing(swap) || (push!(new, position => Origin(assignment, 0, Weak.variable, value, something(swap), index, stand_in)); swaps[position] = typeof(something(swap)))
                end
            end
        end
        isempty(new) && continue
        if !named
            converted = with_swaps(types, swaps, keys(swaps))
            result = call_result!(edges, converted)
            if !known(result)
                # Count argument cannot convert (`hvcat((2, 2), x, 0.5, 1, 2)`): keep positions that convert alone.
                kept = Set(position for position in keys(swaps) if known(call_result!(edges, with_swaps(types, swaps, (position,)))))
                filter!(pair -> first(pair) in kept, new)
                isempty(new) && continue
                converted = with_swaps(types, swaps, kept)
                result = call_result!(edges, converted)
            end
            known(result) || continue
            # Variable type itself changes (`s = 0` then `s += x`), so call result need not.
            all(pair -> last(pair).position > 0, new) && result == CC.widenconst(code.ssavaluetypes[index]) && continue
            alternative = Any[(isnothing(values[position]) && isnothing(held[position])) ? swapped(converted[position], stand_in) : converted[position] for position in eachindex(converted)]
            any(isnothing, alternative) && continue
            call_result!(edges, alternative) == result && continue
        end
        for (_, origin) in new
            key = (origin.index, origin.position)
            haskey(found, key) || key in dropped || (found[key] = origin)
        end
    end
    return length(found) > count
end

"""
Typed code of `instance` with each of `origins` replaced in copy of lowered code; `nothing` when inference gives none.
Adds compiler edges of inference to `edges`.
"""
function converted!(edges::Vector{Any}, instance::Core.MethodInstance, origins::Vector{Origin})::Union{Nothing, Core.CodeInfo}
    interpreter = CC.NativeInterpreter()
    source = CC.retrieve_code_info(instance, CC.get_inference_world(interpreter))
    isnothing(source) && return nothing
    # Copy copies statement expressions too, so edits below leave method's code alone.
    source = copy(source)
    for origin in origins
        statement = source.code[origin.index]::Expr
        # Assignment `s = 0` holds value at argument 2.
        origin.position == 0 ? (statement.args[2] = origin.replacement) : ((assigned(statement)::Expr).args[origin.position] = origin.replacement)
    end
    frame = CC.InferenceState(CC.InferenceResult(instance, CC.typeinf_lattice(interpreter)), source, #=cache_mode=# :no, interpreter)
    isnothing(frame) && return nothing
    CC.typeinf(interpreter, frame)
    append!(edges, frame.edges)
    return CC.is_inferred(frame) ? frame.src : nothing
end

"""Type of statement `index` of typed `code`, widened."""
statement_type(code::Core.CodeInfo, index::Int)::Type = CC.widenconst(code.ssavaluetypes[index])

"""
Whether `changed` code throws at reached statement that returns in `code`: weak value was index or field number.
Inference wraps unreached statement in `Core.Const`; branch that conversion turns off leaves only such statements.
"""
breaks(changed::Core.CodeInfo, code::Core.CodeInfo)::Bool = any(eachindex(code.code)) do index
    !(changed.code[index] isa Core.Const) && statement_type(changed, index) === Union{} && statement_type(code, index) !== Union{}
end

"""Type of `argument` in typed `code`, widened."""
argument_type(code::Core.CodeInfo, argument::Any, parameters::Vector{CC.VarState})::Type = CC.widenconst(CC.argextype(argument, code, parameters))

"""
Store callees with position of stored value; target converts value when its element or field type is concrete.
`out .= xs .* 0.5` lowers to `materialize!`.
"""
const STORES = IdDict{Any, Int}(
    setindex! => 3, setfield! => 4, setproperty! => 4, push! => 3, pushfirst! => 3, append! => 3, fill! => 3, copyto! => 3,
    Base.Broadcast.materialize! => 3,
)

"""
Value statement of typed `code` returns or stores in argument or global: (value, store target type, store); target
`nothing` for return, store `callee => call` for argument and `nothing` for global. `nothing` for other statement.
"""
function exit_value(code::Core.CodeInfo, statement::Any, parameters::Vector{CC.VarState}, arguments::Int)::Union{Nothing, Tuple{Any, Any, Any}}
    statement isa Core.ReturnNode && return isdefined(statement, :val) ? (statement.val, nothing, nothing) : nothing
    call = assigned(statement)
    (call isa Expr && call.head === :call) || return nothing
    callee = CC.argextype(call.args[1], code, parameters)
    callee isa Core.Const || return nothing
    # Lowering turns `global g = v` into `setglobal!(module, :g, v)`.
    if callee.val === Core.setglobal! && length(call.args) == 4
        owner, name = CC.argextype(call.args[2], code, parameters), CC.argextype(call.args[3], code, parameters)
        (owner isa Core.Const && name isa Core.Const) || return nothing
        return call.args[4], Core.get_binding_type(owner.val, name.val), nothing
    end
    (haskey(STORES, callee.val) && length(call.args) >= STORES[callee.val]) || return nothing
    target = resolved(code, call.args[2])
    (target isa Core.SlotNumber && 2 <= target.id <= arguments) || return nothing
    return call.args[STORES[callee.val]], argument_type(code, target, parameters), callee.val => call
end

"""Whether store of `exit_value` converts value: concrete global type, field type, value type of dictionary, or element type."""
function converts(code::Core.CodeInfo, target::Any, store::Any, parameters::Vector{CC.VarState})::Bool
    isnothing(store) && return isconcretetype(target)
    callee, call = store
    callee in (setfield!, setproperty!) || return isconcretetype(target <: AbstractDict ? valtype(target) : eltype(target))
    field = CC.argextype(call.args[3], code, parameters)
    (field isa Core.Const && target isa DataType && isconcretetype(target) && hasfield(target, field.val)) || return false
    return isconcretetype(fieldtype(target, field.val))
end

"""
First statement of typed `left` that returns or stores value whose type differs in `baseline`, with `Exit` kind;
`nothing` when none. Store counts when it writes into argument or global whose type does not convert value (`converts`).
"""
function exit_statement(left::Core.CodeInfo, baseline::Core.CodeInfo, parameters::Vector{CC.VarState}, arguments::Int)::Union{Nothing, Tuple{Int, Exit.T}}
    for (index, statement) in enumerate(left.code)
        exit = exit_value(left, statement, parameters, arguments)
        isnothing(exit) && continue
        value, target, store = exit
        !isnothing(target) && converts(left, target, store, parameters) && continue
        argument_type(left, value, parameters) == argument_type(baseline, value, parameters) || return index, isnothing(target) ? Exit.returned : Exit.stored
    end
    return nothing
end

"""Types of value statement `index` returns, stores or computes, in `left` and in `baseline`."""
function exit_types(left::Core.CodeInfo, baseline::Core.CodeInfo, parameters::Vector{CC.VarState}, arguments::Int, index::Int)::Tuple{Type, Type}
    exit = exit_value(left, left.code[index], parameters, arguments)
    isnothing(exit) && return statement_type(left, index), statement_type(baseline, index)
    return argument_type(left, exit[1], parameters), argument_type(baseline, exit[1], parameters)
end

"""Value id of `argument`: statement index for SSA value, negative slot number for variable; `nothing` otherwise."""
value_id(argument::Any)::Union{Nothing, Int} = argument isa Core.SSAValue ? argument.id : argument isa Core.SlotNumber ? -argument.id : nothing

"""Value id statement `index` defines: assigned variable, or statement itself."""
result_id(statement::Any, index::Int)::Int = statement isa Expr && statement.head === :(=) && statement.args[1] isa Core.SlotNumber ? -statement.args[1].id : index

"""Indexing callees with first index position; index converts to `Int`, so its type cannot escape."""
const INDEXERS = IdDict{Any, Int}(getindex => 3, setindex! => 4, view => 3, Base.maybeview => 3, Base.dotview => 3, checkbounds => 3)

"""Callees whose result carries index on: arithmetic, ranges, iteration and its tuple fields, type assertion."""
const CARRIERS = Base.IdSet{Any}([+, -, *, div, rem, mod, fld, cld, <<, >>, >>>, min, max, abs, (:), Base.OneTo, UnitRange, iterate, getfield, typeassert])

"""Comparisons: `Bool` result drops type of operands."""
const COMPARISONS = Base.IdSet{Any}([<, <=, >, >=, ==, !=, isless, isequal, ===])

"""Use target of value that leaves index use."""
const ESCAPE = typemin(Int)

"""Use target that ends use: index position or comparison."""
const HARMLESS = 0

"""
Value ids of typed `code` used only as index (`INDEXERS`), through arithmetic, ranges, iteration and variables
(`CARRIERS`) and comparisons. Range bound counts when range and its elements are used only for indexing.
"""
function index_only(code::Core.CodeInfo, parameters::Vector{CC.VarState})::Set{Int}
    targets = Dict{Int, Vector{Int}}()
    use!(argument::Any, target::Int)::Nothing = (id = value_id(argument); isnothing(id) || push!(get!(targets, id, Int[]), target); nothing)
    for (index, statement) in enumerate(code.code)
        right, result = assigned(statement), result_id(statement, index)
        if statement isa Core.ReturnNode
            isdefined(statement, :val) && use!(statement.val, ESCAPE)
        elseif right isa Union{Core.SSAValue, Core.SlotNumber}
            use!(right, result)
        elseif right isa Expr && right.head === :call
            callee = CC.argextype(right.args[1], code, parameters)
            callee = callee isa Core.Const ? callee.val : nothing
            for (position, argument) in enumerate(right.args)
                target = if position == 1
                    ESCAPE
                elseif haskey(INDEXERS, callee)
                    position >= INDEXERS[callee] ? HARMLESS : ESCAPE
                else
                    callee in COMPARISONS ? HARMLESS : callee in CARRIERS ? result : ESCAPE
                end
                use!(argument, target)
            end
        elseif right isa Expr
            foreach(argument -> use!(argument, ESCAPE), right.args)
        end
    end
    only = Set(keys(targets))
    # Greatest fixed point: loop variables use themselves.
    changed = true
    while changed
        changed = false
        for id in collect(only)
            all(target -> target == HARMLESS || target in only, targets[id]) && continue
            delete!(only, id)
            changed = true
        end
    end
    return only
end

"""Whether call result `type` can carry widened number: number, array, or lazy broadcast."""
carries_number(type::Type)::Bool = type !== Union{} && (type <: Number || type <: AbstractArray || type <: Base.Broadcast.Broadcasted)

"""First number statement of typed `left` whose type differs in `baseline` and is not index only; `nothing` when none."""
function widened_statement(left::Core.CodeInfo, baseline::Core.CodeInfo, indices::Set{Int})::Union{Nothing, Int}
    for (index, statement) in enumerate(left.code)
        found = statement_type(left, index)
        carries_number(found) && found != statement_type(baseline, index) && !(result_id(statement, index) in indices) && return index
    end
    return nothing
end

"""Whether `argument` of `code` is result of `Core.get_binding_type`: declared type of global."""
function binding_type(code::Core.CodeInfo, argument::Any, parameters::Vector{CC.VarState})::Bool
    argument isa Core.SSAValue || return false
    call = code.code[argument.id]
    return call isa Expr && call.head === :call && CC.argextype(call.args[1], code, parameters) == Core.Const(Core.get_binding_type)
end

"""Type tests that make findings `possible`: branch on type can pick other code for other input type."""
const TYPE_TESTS = Base.IdSet{Any}([isa, <:, ===, ==, !=, isequal])

"""
Whether typed `code` tests type: `x isa Float64`, `T <: Integer`, `T === Float32`. Test of declared global type, which
lowering adds to `global g = v`, does not count.
"""
function type_branch(code::Core.CodeInfo, parameters::Vector{CC.VarState})::Bool
    for statement in code.code
        call = assigned(statement)
        (call isa Expr && call.head === :call) || continue
        callee = CC.argextype(call.args[1], code, parameters)
        (callee isa Core.Const && callee.val in TYPE_TESTS) || continue
        any(argument -> binding_type(code, argument, parameters), call.args[2:end]) && continue
        callee.val in (isa, <:) && return true
        any(argument -> argument_type(code, argument, parameters) <: Type, call.args[2:end]) && return true
    end
    return false
end

"""
Changes typed `code` of `instance` makes by weak values (`Change`), ordered by statement and position, and whether it
tests type (`type_branch`). Adds compiler edges of every inference scan runs to `edges`. Weak value whose conversion
makes statement throw is dropped: it was index or field number there.
"""
function changes!(edges::Vector{Any}, instance::Core.MethodInstance, code::Core.CodeInfo)::Tuple{Vector{Change}, Bool}
    parameters = CC.sptypes_from_meth_instance(instance)
    found, dropped = Dict{Tuple{Int, Int}, Origin}(), Set{Tuple{Int, Int}}()
    meetings!(found, dropped, edges, code, parameters) || return Change[], false
    origins() = sort!(collect(values(found)); by = origin -> (origin.index, origin.position))
    baseline, rounds = code, 0
    while true
        baseline = converted!(edges, instance, origins())
        if isnothing(baseline) || breaks(baseline, code)
            for (key, origin) in collect(found)
                alone = converted!(edges, instance, [origin])
                isnothing(alone) || breaks(alone, code) || continue
                push!(dropped, key)
                delete!(found, key)
            end
            baseline = isempty(found) ? nothing : converted!(edges, instance, origins())
            (isnothing(baseline) || breaks(baseline, code)) && return Change[], false
        end
        (rounds += 1) < ROUNDS && meetings!(found, dropped, edges, baseline, parameters) || break
    end
    indices, arguments = index_only(code, parameters), Int(instance.def.nargs)
    changed = Change[]
    for origin in origins()
        rest = filter(other -> other !== origin, origins())
        left = isempty(rest) ? code : converted!(edges, instance, rest)
        isnothing(left) && continue
        exit = exit_statement(left, baseline, parameters, arguments)
        if isnothing(exit)
            widened = widened_statement(left, baseline, indices)
            isnothing(widened) && continue
            exit = (widened, Exit.intermediate)
        end
        at, kind = exit
        push!(changed, Change(origin, kind, at, exit_types(left, baseline, parameters, arguments, at)...))
    end
    return changed, type_branch(code, parameters)
end

end
