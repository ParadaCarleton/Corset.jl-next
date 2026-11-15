"""
Stand-in signatures: concrete argument types `inference` stage infers package methods with.
Generic argument gets stand-ins that fit its bound; package abstract type gets each package struct below it.
"""
module Signatures

using ..StandIns: StandIns, ArrayStandIn, DenseStandIn, FunctionStandIn
using ..Facts: tuple_parameters

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

"""
Members of `candidates` below `bound`. Loop instead of closure: closure capturing type value has type parameter
`Type{value}`, so it compiles once per bound.
"""
function fitting(candidates::Any, bound::Type)::Vector{Type}
    found = Type[]
    for candidate in candidates
        candidate <: bound && push!(found, candidate)
    end
    return found
end

"""Array stand-ins for `bound`: element `Any` when bound allows any element; number stand-ins; else bound element type."""
function arrays(bound::Type)::Vector{Type}
    for dimensions in 1:3, kind in (ArrayStandIn, DenseStandIn)
        kind{Any, dimensions} <: bound && return Type[kind{Any, dimensions}]
        found = fitting((kind{element, dimensions} for element in StandIns.NUMBERS), bound)
        isempty(found) || return found
        kind{eltype(bound), dimensions} <: bound && return Type[kind{eltype(bound), dimensions}]
    end
    return Type[]
end

"""Concrete types that stand for argument of declared type `bound`; `structs` are package struct stand-ins. Empty when none fits."""
function stand_ins(bound::Type, structs::Vector{<:Type})::Vector{Type}
    bound === Any && return Type[]
    isconcretetype(bound) && return Type[bound]
    numbers = fitting(StandIns.NUMBERS, bound)
    isempty(numbers) || return numbers
    found = bound <: AbstractArray ? arrays(bound) : Type[]
    isempty(found) || return found
    FunctionStandIn <: bound && return Type[FunctionStandIn]
    return fitting(structs, bound)
end

"""`type` with `value` for its outer type variable; `nothing` when struct parameter bound inside `type` rejects `value`."""
function applied(type::UnionAll, value::Type)::Union{Nothing, Type}
    return try
        type{value}
    catch error
        # `Bounded{E, V} where V <: AbstractVector` takes `V` only below `AbstractVector{E}`, as struct declares.
        error isa TypeError || rethrow()
        nothing
    end
end

"""
Types with stand-ins for type variables of `type`, outermost first; variable that no stand-in fits stays free.
Stops after more than `LIMIT` types, so caller sees overflow.
"""
function instantiate(type::Type, structs::Vector{<:Type})::Vector{Type}
    type isa UnionAll || return Type[type]
    variable, applications = type.var, Type[]
    for value in stand_ins(variable.ub, structs)
        variable.lb <: value || continue
        application = applied(type, value)
        isnothing(application) || push!(applications, application)
    end
    isempty(applications) && return Type[UnionAll(variable, inner) for inner in instantiate(type.body, structs)]
    found = Type[]
    for application in applications
        append!(found, instantiate(application, structs))
        length(found) > LIMIT && break
    end
    return found
end

"""Most rounds of `struct_stand_ins`: depth of struct parameter bounded by package struct."""
const ROUNDS = 4

"""`type` with each free variable set to its upper bound; stays `UnionAll` when struct rejects bound."""
function bounded(type::Type)::Type
    type isa UnionAll || return type
    application = applied(type, type.var.ub)
    return isnothing(application) ? type : bounded(application)
end

"""Whether struct `type` has values: concrete, and no field type `Union{}` (`Sized{Any}` for `x::NTuple{N}`)."""
inhabited(type::Type)::Bool = isconcretetype(type) && !any(field -> field === Union{}, fieldtypes(type))

"""First member of each of `groups`, then second of each, and so on."""
function interleaved(groups::Vector{Vector{Type}})::Vector{Type}
    found = Type[]
    for index in 1:maximum(length, groups; init = 0), group in groups
        index <= length(group) && push!(found, group[index])
    end
    return found
end

"""
Concrete stand-ins for package `structs` as written (`UnionAll` for parametric struct). Each round gives parameters
struct stand-ins of round before, so `Outer{S <: Inner}` gets one once `Inner` has one. Parameter no stand-in fits
takes its bound: field of type `Any` holds data that gives no findings, as `::Any` argument does. Union argument cut
at `LIMIT` reaches most structs and most data: stand-ins without bound come first, and first stand-in of each struct
comes before second of any.
"""
function struct_stand_ins(structs::Vector{<:Type})::Vector{Type}
    found = Type[]
    for _ in 1:ROUNDS
        exact, filled = Vector{Type}[], Vector{Type}[]
        for type in structs
            push!(exact, Type[]), push!(filled, Type[])
            for instance in instantiate(type, found)
                stand_in = bounded(instance)
                inhabited(stand_in) && push!(stand_in === instance ? last(exact) : last(filled), stand_in)
            end
        end
        # No `unique!`: target methods invalidate it on `Vector{Type}`, and distinct structs give distinct stand-ins.
        next = [interleaved(exact); interleaved(filled)]
        next == found && break
        found = next
    end
    return found
end

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

"""
First `limit` combinations of one entry per position of `options`, first position fastest as `Iterators.product`
orders them, and whether more exist. `Iterators.product` over splatted options compiles once per argument count.
"""
function combinations(options::Vector{Vector{Any}}, limit::Int)::Tuple{Vector{Vector{Any}}, Bool}
    found, indices = Vector{Any}[], ones(Int, length(options))
    more = !any(isempty, options)
    while more
        length(found) < limit || return found, true
        push!(found, Any[options[position][indices[position]] for position in eachindex(options)])
        position = findfirst(position -> indices[position] < length(options[position]), eachindex(options))
        more = !isnothing(position)
        more && (indices[1:(position - 1)] .= 1; indices[position] += 1)
    end
    return found, false
end

"""Stand-in signatures of `method`; `structs` come from `struct_stand_ins`."""
function method_signatures(method::Method, structs::Vector{<:Type})::MethodSignatures
    instantiated = instantiate(method.sig, structs)
    signatures, bare = Type[], Int[]
    over_limit = length(instantiated) > LIMIT
    for signature in first(instantiated, LIMIT)
        parameters = tuple_parameters(signature)
        options = Vector{Any}[Any[first(parameters)]]
        # Loop instead of generator: closure capturing `signature` compiles once per method (`fitting`).
        for position in 2:length(parameters)
            push!(options, choices(parameters[position], position - 1, signature, structs, bare))
        end
        found, more = combinations(options, LIMIT - length(signatures))
        over_limit |= more
        for combination in found
            push!(signatures, Base.rewrap_unionall(Tuple{combination...}, signature))
        end
    end
    return MethodSignatures(method, signatures, sort!(unique!(bare)), over_limit)
end

end
