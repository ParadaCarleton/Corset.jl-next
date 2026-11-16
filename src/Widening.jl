"""
`inference` stage scan for weak values that widen input types (`type-disruption`, `intermediate-widening`).

Weak value: number literal, constant, call of weak values only (`sqrt(2)`), variable assigned one, or Base number type
name. Inputs combine by normal promotion; weak value must not change result type. Only float input counts: Julia
promotes small integers to `Int` on purpose (`sum(Int32[1])`, index math).
Scan converts each weak value that meets input to stand-in type in copy of lowered code, and native inference runs on
it. Rounds repeat until no new weak value meets input, so `x * 2.0 + 1.0` converts both. Then each weak value stays
unconverted alone: changed type of returned or stored value is escape; changed number intermediate only is widening.
"""
module Widening

using ..Facts: Weak, Exit
using ..StandIns: StandIns, FloatStandIn

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
`value` is number, or number type for name. `replacement` takes its place: `value` converted to float stand-in, or
float stand-in itself for name. `site` is first statement where weak value meets input.
"""
struct Origin
    index::Int
    position::Int
    kind::Weak.T
    value::Any
    replacement::Any
    site::Int
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

"""Whether `type` holds float stand-in, parameters and union members included."""
function holds_float(type::Any)::Bool
    type === FloatStandIn && return true
    type isa Union && return holds_float(type.a) || holds_float(type.b)
    type isa UnionAll && return holds_float(type.body)
    return type isa DataType && any(holds_float, type.parameters)
end

"""
`type` with float stand-in replaced by `Float64`, parameters included; `nothing` when parameter bound rejects
`Float64`. Meeting test swaps input to it.
"""
function swapped(type::Any)::Any
    type === FloatStandIn && return Float64
    type isa Union && return Union{swapped(type.a), swapped(type.b)}
    type isa DataType || return type
    isempty(type.parameters) && return type
    return try
        type.name.wrapper{Any[swapped(parameter) for parameter in type.parameters]...}
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

"""
Whether `value` is weak data: number, or tuple of numbers (`evalpoly` coefficients). `Bool` promotes to any number type,
so it never widens; leaving it out saves meeting tests.
"""
function weak_data(value::Any)::Bool
    value isa Number && return !(value isa Bool)
    value isa Tuple || return false
    isempty(value) && return false
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
        call, type = statement_call(code.code[argument.id]), code.ssavaluetypes[argument.id]
        isnothing(call) && return nothing
        length(call.args) >= 2 || return nothing
        type isa Core.Const || return nothing
        weak_data(type.val) || return nothing
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

"""
Call expression of `statement`, through slot assignment (`_4 = f(x)`); `nothing` for other statement. Inference drops
`isa` narrowing after `(x isa Expr && …) || continue`; `isnothing` test on this result keeps it.
"""
function statement_call(statement::Any)::Union{Nothing, Expr}
    call = assigned(statement)
    return call isa Expr && call.head === :call ? call : nothing
end

"""Weak values each variable of `code` takes from assignment, as (statement, value) pairs: `s = 0` makes `s` weak."""
function variable_origins(code::Core.CodeInfo)::Dict{Int, Vector{Tuple{Int, Any}}}
    found = Dict{Int, Vector{Tuple{Int, Any}}}()
    for (index, statement) in enumerate(code.code)
        statement isa Expr || continue
        statement.head === :(=) || continue
        slot = statement.args[1]
        slot isa Core.SlotNumber || continue
        value = weak(code, statement.args[2])
        # Type name holds no number, so `replacement` drops it.
        isnothing(value) || push!(get!(found, slot.id, Tuple{Int, Any}[]), (index, value[1]))
    end
    return found
end

"""
Value that replaces weak `value`: real number converted to float stand-in, tuple element-wise; `nothing` for other
value and for number without conversion.
"""
function replacement(value::Any)::Union{Nothing, Some{Any}}
    if value isa Tuple
        elements = Any[]
        for element in value
            swap = replacement(element)
            isnothing(swap) && return nothing
            push!(elements, something(swap))
        end
        return Some{Any}(Tuple(elements))
    end
    value isa Real || return nothing
    return try
        Some{Any}(convert(FloatStandIn, value))
    catch error
        # Package number type without `Float32` conversion cannot take input type.
        error isa MethodError || rethrow()
        nothing
    end
end

"""
Whether Base number type `name` widens float input: `Float64(x)`. Conversion to narrower type (`Float16(x)`) or other
kind (`Int(x)`) changes input on purpose; `Float32` absorbs both.
"""
function renames(name::Type)::Bool
    model = StandIns.model(FloatStandIn)
    return name !== model && promote_type(name, model) === name
end

"""Whether position `position` of call to `callee` takes type name that converts: callee, `convert(T, x)`, `T.(x)`."""
conversion(callee::Any, position::Int)::Bool = position == 1 || (position == 2 && (callee === convert || callee === Base.Broadcast.broadcasted))

"""
Result type of call with argument types `types`, callee first, over at most `MATCHES` methods; `Any` when unknown.
Adds instances it infers to compiler `edges`.
"""
function call_result!(edges::Vector{Any}, types::Vector{Any})::Type
    matches = Base._methods_by_ftype(Tuple{types...}, MATCHES, Base.get_world_counter())
    matches isa Vector || return Any
    isempty(matches) && return Any
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

"""Type call result `type` stands for: array that lazy broadcast materializes to, else `type`. Adds to `edges`."""
materialized!(edges::Vector{Any}, type::Type)::Type = type <: Base.Broadcast.Broadcasted ? call_result!(edges, Any[typeof(Base.Broadcast.materialize), type]) : type

"""Argument `types` with type of each of `positions` replaced by its converted type in `swaps`."""
function with_swaps(types::Vector{Any}, swaps::Dict{Int, Any}, positions::Any)::Vector{Any}
    converted = copy(types)
    for position in positions
        converted[position] = swaps[position]
    end
    return converted
end

"""
Add to `found` weak values of typed `code` that meet input, except `dropped` keys; whether any is new. Call meets
input when argument holds float stand-in, weak value converts, result type changes with weak values converted, and
input absorbs them: with input swapped to `Float64`, conversion changes nothing. So `x => 0.5` and `get(table, x, 0.5)`
do not meet `x`. Name that converts input meets it at once. Builtins (`getfield(t, 2)`) change no result type, so scan
skips them. Adds instances meeting test infers to compiler `edges`.
"""
function meetings!(found::Dict{Tuple{Int, Int}, Origin}, dropped::Set{Tuple{Int, Int}}, edges::Vector{Any}, code::Core.CodeInfo, parameters::Vector{CC.VarState})::Bool
    variables = variable_origins(code)
    count = length(found)
    for (index, statement) in enumerate(code.code)
        call = statement_call(statement)
        isnothing(call) && continue
        callee = CC.argextype(call.args[1], code, parameters)
        callee = callee isa Core.Const ? callee.val : nothing
        callee isa Core.Builtin && continue
        types = Any[CC.widenconst(CC.argextype(argument, code, parameters)) for argument in call.args]
        values = Union{Nothing, Tuple{Any, Weak.T}}[weak(code, argument) for argument in call.args]
        held = Union{Nothing, Vector{Tuple{Int, Any}}}[(read = resolved(code, argument); read isa Core.SlotNumber ? get(variables, read.id, nothing) : nothing) for argument in call.args]
        any(position -> isnothing(values[position]) && isnothing(held[position]) && holds_float(types[position]), eachindex(types)) || continue
        # Origins by call position, and type each position takes once its weak value converts.
        new, swaps, named = Pair{Int, Origin}[], Dict{Int, Any}(), false
        for position in eachindex(call.args)
            if !isnothing(values[position])
                value, kind = something(values[position])
                if kind == Weak.name
                    (conversion(callee, position) && renames(value)) || continue
                    push!(new, position => Origin(index, position, kind, value, FloatStandIn, index))
                    swaps[position], named = Type{FloatStandIn}, true
                else
                    swap = replacement(value)
                    position > 1 && !isnothing(swap) || continue
                    push!(new, position => Origin(index, position, kind, value, something(swap), index))
                    swaps[position] = typeof(something(swap))
                end
            elseif !isnothing(held[position])
                for (assignment, value) in something(held[position])
                    swap = replacement(value)
                    isnothing(swap) || (push!(new, position => Origin(assignment, 0, Weak.variable, value, something(swap), index)); swaps[position] = typeof(something(swap)))
                end
            end
        end
        isempty(new) && continue
        if !named
            positions = Set(keys(swaps))
            result = call_result!(edges, with_swaps(types, swaps, positions))
            if !known(result)
                # Count argument cannot convert (`hvcat((2, 2), x, 0.5, 1, 2)`): keep positions that convert alone.
                filter!(position -> known(call_result!(edges, with_swaps(types, swaps, (position,)))), positions)
                filter!(pair -> first(pair) in positions, new)
                isempty(new) && continue
                result = call_result!(edges, with_swaps(types, swaps, positions))
            end
            known(result) || continue
            # Variable type itself changes (`s = 0` then `s += x`), so call result need not. Lazy broadcast type holds
            # argument types, so `xs .+ 1` changes it; array it materializes to stays same.
            all(pair -> last(pair).position > 0, new) && materialized!(edges, result) == materialized!(edges, statement_type(code, index)) && continue
            wide = Any[(isnothing(values[position]) && isnothing(held[position])) ? swapped(types[position]) : types[position] for position in eachindex(types)]
            any(isnothing, wide) && continue
            absorbed = call_result!(edges, wide)
            known(absorbed) && materialized!(edges, absorbed) == materialized!(edges, call_result!(edges, with_swaps(wide, swaps, positions))) || continue
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
    call = statement_call(statement)
    isnothing(call) && return nothing
    callee = CC.argextype(call.args[1], code, parameters)
    callee isa Core.Const || return nothing
    # Lowering turns `global g = v` into `setglobal!(module, :g, v)`.
    if callee.val === Core.setglobal! && length(call.args) == 4
        owner, name = CC.argextype(call.args[2], code, parameters), CC.argextype(call.args[3], code, parameters)
        owner isa Core.Const || return nothing
        name isa Core.Const || return nothing
        return call.args[4], Core.get_binding_type(owner.val, name.val), nothing
    end
    (haskey(STORES, callee.val) && length(call.args) >= STORES[callee.val]) || return nothing
    target = resolved(code, call.args[2])
    target isa Core.SlotNumber || return nothing
    2 <= target.id <= arguments || return nothing
    return call.args[STORES[callee.val]], argument_type(code, target, parameters), callee.val => call
end

"""Whether store of `exit_value` converts value: concrete global, field, dictionary value or element type."""
function converts(code::Core.CodeInfo, target::Any, store::Any, parameters::Vector{CC.VarState})::Bool
    isnothing(store) && return isconcretetype(target)
    callee, call = store
    # Identity test: `in` compares with `==`, which gives `missing` for `missing` callee.
    callee === setfield! || callee === setproperty! || return isconcretetype(target <: AbstractDict ? valtype(target) : eltype(target))
    field = CC.argextype(call.args[3], code, parameters)
    field isa Core.Const || return false
    target isa DataType || return false
    (isconcretetype(target) && hasfield(target, field.val)) || return false
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

"""Whether call result `type` can carry widened number: number, array, or lazy broadcast."""
carries_number(type::Type)::Bool = type !== Union{} && (type <: Number || type <: AbstractArray || type <: Base.Broadcast.Broadcasted)

"""First number statement of typed `left` whose type differs in `baseline`; `nothing` when none."""
function widened_statement(left::Core.CodeInfo, baseline::Core.CodeInfo)::Union{Nothing, Int}
    for index in eachindex(left.code)
        found = statement_type(left, index)
        carries_number(found) && found != statement_type(baseline, index) && return index
    end
    return nothing
end

"""Whether `argument` of `code` is result of `Core.get_binding_type`: declared type of global."""
function binding_type(code::Core.CodeInfo, argument::Any, parameters::Vector{CC.VarState})::Bool
    argument isa Core.SSAValue || return false
    call = statement_call(code.code[argument.id])
    return !isnothing(call) && CC.argextype(call.args[1], code, parameters) == Core.Const(Core.get_binding_type)
end

"""Type tests that make findings `possible`: branch on type can pick other code for other input type."""
const TYPE_TESTS = Base.IdSet{Any}([isa, <:, ===, ==, !=, isequal])

"""
Whether typed `code` tests type: `x isa Float64`, `T <: Integer`, `T === Float32`. Test of declared global type, which
lowering adds to `global g = v`, does not count.
"""
function type_branch(code::Core.CodeInfo, parameters::Vector{CC.VarState})::Bool
    for statement in code.code
        call = statement_call(statement)
        isnothing(call) && continue
        callee = CC.argextype(call.args[1], code, parameters)
        (callee isa Core.Const && callee.val in TYPE_TESTS) || continue
        any(argument -> binding_type(code, argument, parameters), call.args[2:end]) && continue
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
    arguments = Int(instance.def.nargs)
    changed = Change[]
    for origin in origins()
        rest = filter(other -> other !== origin, origins())
        left = isempty(rest) ? code : converted!(edges, instance, rest)
        isnothing(left) && continue
        exit = exit_statement(left, baseline, parameters, arguments)
        if isnothing(exit)
            widened = widened_statement(left, baseline)
            isnothing(widened) && continue
            exit = (widened, Exit.intermediate)
        end
        at, kind = exit
        push!(changed, Change(origin, kind, at, exit_types(left, baseline, parameters, arguments, at)...))
    end
    return changed, type_branch(code, parameters)
end

end
