"""
Stand-in signatures: concrete argument types `inference` stage infers package methods with.
Generic argument gets stand-ins that fit its bound; package abstract type gets each package struct below it.
"""
module Signatures

using ..StandIns: StandIns, ArrayStandIn, DenseStandIn, FunctionStandIn

"""Most signatures per method; inference skips further combinations."""
const LIMIT = 8

"""
Stand-in signatures of package `method`, at most `LIMIT`; `over_limit` when more combinations exist. `bare` lists
argument positions (1 is first argument after callee) that keep declared type, since no stand-in fits it.
"""
struct MethodSignatures
    method::Method
    signatures::Vector{Type}
    bare::Vector{Int}
    over_limit::Bool
end

"""Array stand-ins for `bound`: element `Any` when bound allows any element; number stand-ins; else bound element type."""
function arrays(bound::Type)::Vector{Type}
    for dimensions in 1:3, kind in (ArrayStandIn, DenseStandIn)
        kind{Any, dimensions} <: bound && return Type[kind{Any, dimensions}]
        found = Type[kind{element, dimensions} for element in StandIns.NUMBERS if kind{element, dimensions} <: bound]
        isempty(found) || return found
        kind{eltype(bound), dimensions} <: bound && return Type[kind{eltype(bound), dimensions}]
    end
    return Type[]
end

"""Concrete types that stand for argument of declared type `bound`; `structs` are package struct stand-ins. Empty when none fits."""
function stand_ins(bound::Type, structs::Vector{<:Type})::Vector{Type}
    bound === Any && return Type[]
    isconcretetype(bound) && return Type[bound]
    numbers = Type[number for number in StandIns.NUMBERS if number <: bound]
    isempty(numbers) || return numbers
    found = bound <: AbstractArray ? arrays(bound) : Type[]
    isempty(found) || return found
    FunctionStandIn <: bound && return Type[FunctionStandIn]
    return Type[type for type in structs if type <: bound]
end

"""
Types with stand-ins for type variables of `type`, outermost first; variable that no stand-in fits stays free.
Stops after more than `LIMIT` types, so caller sees overflow.
"""
function instantiate(type::Type, structs::Vector{<:Type})::Vector{Type}
    type isa UnionAll || return Type[type]
    variable = type.var
    values = filter(value -> variable.lb <: value, stand_ins(variable.ub, structs))
    isempty(values) && return Type[UnionAll(variable, inner) for inner in instantiate(type.body, structs)]
    found = Type[]
    for value in values
        append!(found, instantiate(type{value}, structs))
        length(found) > LIMIT && break
    end
    return found
end

"""Concrete stand-ins for package `structs` as written (`UnionAll` for parametric struct); parameters get no struct stand-ins."""
struct_stand_ins(structs::Vector{<:Type})::Vector{Type} =
    filter(isconcretetype, reduce(vcat, (instantiate(type, Type[]) for type in structs); init = Type[]))

"""Choices for argument `parameter` of `signature`; records position in `bare` when no stand-in fits."""
function choices(parameter::Any, position::Int, signature::Type, structs::Vector{<:Type}, bare::Vector{Int})::Vector{Any}
    element = Base.unwrapva(parameter)
    # Free type variable keeps whole signature generic, so its arguments keep declared types.
    found = signature isa UnionAll ? Type[] : stand_ins(element, structs)
    isempty(found) && !Base.isdispatchelem(element) && push!(bare, position)
    isempty(found) && return Any[parameter]
    # Method signature spells fixed-length `Vararg` as separate arguments, so `Vararg` here has open length.
    return Any[Base.isvarargtype(parameter) ? Vararg{value} : value for value in found]
end

"""Stand-in signatures of `method`; `structs` come from `struct_stand_ins`."""
function method_signatures(method::Method, structs::Vector{<:Type})::MethodSignatures
    instantiated = instantiate(method.sig, structs)
    signatures, bare = Type[], Int[]
    over_limit = length(instantiated) > LIMIT
    for signature in first(instantiated, LIMIT)
        parameters = Base.unwrap_unionall(signature).parameters
        options = Vector{Any}[Any[first(parameters)]]
        append!(options, (choices(parameters[position], position - 1, signature, structs, bare) for position in 2:length(parameters)))
        for combination in Iterators.product(options...)
            length(signatures) < LIMIT || (over_limit = true; break)
            push!(signatures, Base.rewrap_unionall(Tuple{combination...}, signature))
        end
    end
    return MethodSignatures(method, signatures, sort!(unique!(bare)), over_limit)
end

end
