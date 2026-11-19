"""
`inference` stage scan for hard-coded `Array` construction that drops caller's array type (`type-disruption`, F16).

Construction: `zeros`, `ones`, `fill`, `similar` of `Array` type, and `Array` type called with `undef`
(`Vector{T}(undef, n)`). Template: argument of stand-in array type. Scan gives each construction stand-in array type of
its template in copy of lowered code, as `similar(template, T, dims)` would, and native inference runs on it. Then each
construction stays unconverted alone: changed type of returned or stored value is escape; call that takes construction
and array from input is meeting.
"""
module HardArrays

using ..Facts: Exit, tuple_parameters
using ..StandIns: Templated, array_stand_in
using ..Widening: Swap, converted!, breaks, exit_statement, type_branch, statement_call, argument_type, statement_type, resolved

const CC = Core.Compiler

"""Constructors that fill new `Array` whatever their arguments."""
const FILLS = Base.IdSet{Any}([zeros, ones, fill])

"""
Hard-coded construction at statement `index` of typed code: `callee` value, and argument slot of `template` whose array
type fix takes; `array` is type construction builds.
"""
struct Construction
    index::Int
    callee::Any
    template::Int
    array::Type
end

"""Effect of leaving `construction` unconverted while others convert: type differs at statement `at`, as `exit` says."""
struct Change
    construction::Construction
    exit::Exit.T
    at::Int
end

"""
Whether `type` holds array stand-in, parameters, variable bounds and union members included: lazy broadcast of
input holds one, view of open stand-in holds it as bound.
"""
function holds_array(type::Any)::Bool
    array_stand_in(type) && return true
    type isa TypeVar && return holds_array(type.ub)
    type isa Union && return holds_array(type.a) || holds_array(type.b)
    type = Base.unwrap_unionall(type)
    return type isa DataType && any(holds_array, type.parameters)
end

"""Argument slots of `instance` with array stand-in type, in order."""
function templates(instance::Core.MethodInstance)::Vector{Int}
    arguments = tuple_parameters(instance.specTypes)
    return [slot for slot in 2:length(arguments) if array_stand_in(arguments[slot])]
end

"""Whether `call` of typed `code` builds hard-coded `Array`: constructor in `FILLS`, `similar(Vector{T}, n)` or `Vector{T}(undef, n)`."""
function constructs(code::Core.CodeInfo, call::Expr, parameters::Vector{CC.VarState})::Bool
    callee = CC.argextype(call.args[1], code, parameters)
    callee isa Core.Const || return false
    callee.val in FILLS && return true
    length(call.args) >= 2 || return false
    first = CC.argextype(call.args[2], code, parameters)
    callee.val === similar && return first isa Core.Const && first.val isa Type && first.val !== Union{} && first.val <: Array
    return callee.val isa Type && callee.val !== Union{} && callee.val <: Array && CC.widenconst(first) === UndefInitializer
end

"""
Template slot of construction `call` in typed `code`: first of `slots` that argument call reads (`zeros(length(xs))`),
else first of `slots`.
"""
function template_of(code::Core.CodeInfo, call::Expr, slots::Vector{Int})::Int
    for argument in call.args[2:end]
        argument isa Core.SSAValue || continue
        inner = statement_call(code.code[argument.id])
        isnothing(inner) && continue
        for read in inner.args
            read = resolved(code, read)
            read isa Core.SlotNumber && read.id in slots && return read.id
        end
    end
    return first(slots)
end

"""Hard-coded constructions of typed `code` with `slots` as templates."""
function constructions(code::Core.CodeInfo, parameters::Vector{CC.VarState}, slots::Vector{Int})::Vector{Construction}
    found = Construction[]
    for (index, statement) in enumerate(code.code)
        call = statement_call(statement)
        isnothing(call) && continue
        constructs(code, call, parameters) || continue
        array = statement_type(code, index)
        (array !== Union{} && array <: Array) || continue
        push!(found, Construction(index, (CC.argextype(call.args[1], code, parameters)::Core.Const).val, template_of(code, call, slots), array))
    end
    return found
end

"""Replacements that give `chosen` stand-in array type of their template in `instance`."""
function swaps(instance::Core.MethodInstance, chosen::Vector{Construction})::Vector{Swap}
    arguments = tuple_parameters(instance.specTypes)
    wrapper(slot::Int)::UnionAll = Base.unwrap_unionall(arguments[slot]).name.wrapper
    return Swap[(index = construction.index, position = 1, value = Templated{wrapper(construction.template)}(construction.callee)) for construction in chosen]
end

"""
First call of typed `left` that takes value whose type differs in `baseline` and value that holds array from input in
`code`; `nothing` when none. One value can be both: tuple of construction and input. Builtins (`tuple`, `getfield`)
only move values.
"""
function meeting(left::Core.CodeInfo, baseline::Core.CodeInfo, code::Core.CodeInfo, parameters::Vector{CC.VarState})::Union{Nothing, Int}
    for (index, statement) in enumerate(left.code)
        call = statement_call(statement)
        isnothing(call) && continue
        callee = CC.argextype(call.args[1], left, parameters)
        callee isa Core.Const && callee.val isa Core.Builtin && continue
        arguments = call.args[2:end]
        any(argument -> argument_type(left, argument, parameters) != argument_type(baseline, argument, parameters), arguments) || continue
        any(argument -> holds_array(argument_type(code, argument, parameters)), arguments) && return index
    end
    return nothing
end

"""
Changes typed `code` of `instance` makes by hard-coded constructions (`Change`), in statement order, and whether code
tests type (`Widening.type_branch`). Construction whose conversion makes statement throw is dropped: callee takes
`Array` only there. Adds compiler edges of every inference scan runs to `edges`.
"""
function changes!(edges::Vector{Any}, instance::Core.MethodInstance, code::Core.CodeInfo)::Tuple{Vector{Change}, Bool}
    parameters, slots = CC.sptypes_from_meth_instance(instance), templates(instance)
    isempty(slots) && return Change[], false
    found = constructions(code, parameters, slots)
    isempty(found) && return Change[], false
    baseline = converted!(edges, instance, swaps(instance, found))
    if isnothing(baseline) || breaks(baseline, code)
        kept = Construction[]
        for construction in found
            alone = converted!(edges, instance, swaps(instance, [construction]))
            isnothing(alone) || breaks(alone, code) || push!(kept, construction)
        end
        found = kept
        baseline = isempty(found) ? nothing : converted!(edges, instance, swaps(instance, found))
        (isnothing(baseline) || breaks(baseline, code)) && return Change[], false
    end
    arguments, changed = Int(instance.def.nargs), Change[]
    for construction in found
        rest = Construction[other for other in found if other.index != construction.index]
        left = isempty(rest) ? code : converted!(edges, instance, swaps(instance, rest))
        isnothing(left) && continue
        exit = exit_statement(left, baseline, parameters, arguments)
        if isnothing(exit)
            met = meeting(left, baseline, code, parameters)
            isnothing(met) && continue
            exit = (met, Exit.intermediate)
        end
        push!(changed, Change(construction, last(exit), first(exit)))
    end
    return changed, type_branch(code, parameters)
end

end
