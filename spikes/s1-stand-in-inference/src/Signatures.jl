"""
Map package method signatures to concrete stand-in signatures.
"""
module Signatures

using ..StandIns
using InteractiveUtils: subtypes

export package_methods, stand_in_signatures, SignatureNote

"Notes on how one argument was filled; drives coverage counts."
const SignatureNote = Symbol

"Every method whose defining module is `pkg` or one of its submodules."
function package_methods(pkg::Module)::Vector{Method}
    mods = Set{Module}([pkg]); collect_submodules!(mods, pkg)
    found = Method[]
    Base.visit(Core.methodtable) do m
        m isa Method && m.module in mods && push!(found, m)
    end
    found
end

function collect_submodules!(mods::Set{Module}, m::Module)::Nothing
    for n in names(m; all = true)
        isdefined(m, n) || continue
        sub = getfield(m, n)
        if sub isa Module && parentmodule(sub) === m && sub !== m && !(sub in mods)
            push!(mods, sub); collect_submodules!(mods, sub)
        end
    end
end

in_package(T, mods::Set{Module})::Bool = parentmodule(Base.unwrap_unionall(T)) in mods

"Concrete types package defines below abstract `T`, parameters filled from bounds."
function concrete_subtypes(T, mods::Set{Module}, notes::Vector{Symbol}, depth::Int)::Vector{Any}
    found = Any[]
    for S in subtypes(Base.unwrap_unionall(T) isa DataType ? Base.unwrap_unionall(T).name.wrapper : T)
        in_package(S, mods) || continue
        if isabstracttype(Base.unwrap_unionall(S))
            append!(found, concrete_subtypes(S, mods, notes, depth))
        else
            filled = fill_parameters(S, mods, notes, depth + 1)
            filled isa Type && filled <: T && push!(found, filled)
        end
    end
    found
end

"Fill free parameters of `S` from their bounds; keep a parameter free when no stand-in fits."
function fill_parameters(S, mods::Set{Module}, notes::Vector{Symbol}, depth::Int)
    S isa UnionAll || return S
    depth > 3 && return S
    body = S
    free = TypeVar[]
    while body isa UnionAll
        tv = body.var
        cands = typevar_candidates(tv, mods, notes, depth)
        if isempty(cands)
            push!(free, tv); body = body.body
        else
            body = try body{first(cands)} catch; (push!(free, tv); body.body) end
        end
    end
    isempty(free) ? body : foldr((tv, b) -> UnionAll(tv, b), free; init = body)
end

"Stand-in candidates for type variable `tv` from its upper bound."
function typevar_candidates(tv::TypeVar, mods::Set{Module}, notes::Vector{Symbol}, depth::Int)::Vector{Any}
    tv.ub === Any && return Any[]
    argument_candidates(tv.ub, mods, notes, depth)
end

"Concrete candidates for one argument type; empty when no stand-in applies."
function argument_candidates(A, mods::Set{Module}, notes::Vector{Symbol}, depth::Int = 0)::Vector{Any}
    A === Any && return Any[]
    A isa TypeVar && return Any[]
    if A isa Type && A <: Number
        c = Any[S for S in (FloatStandIn, IntStandIn) if S <: A]
        isempty(c) && push!(notes, :number_without_stand_in)
        return c
    end
    if A isa Type && A <: AbstractArray
        for N in 1:3, E in (FloatStandIn, IntStandIn, Symbol)
            ArrayStandIn{E, N} <: A || continue
            E === Symbol && (push!(notes, :array_eltype_assumed); return Any[ArrayStandIn{FloatStandIn, N}])
            E === IntStandIn && return Any[ArrayStandIn{IntStandIn, N}]
            return Any[ArrayStandIn{E, N} for E in (FloatStandIn, IntStandIn) if ArrayStandIn{E, N} <: A]
        end
        E = eltype(A)
        if isconcretetype(E)
            for N in 1:3
                ArrayStandIn{E, N} <: A && return Any[ArrayStandIn{E, N}]
            end
        end
        push!(notes, :array_without_stand_in)
        return Any[]
    end
    A isa Type && FunctionStandIn <: A && A !== Any && return Any[FunctionStandIn]
    if A isa Type && in_package(A, mods)
        U = Base.unwrap_unionall(A)
        if U isa DataType && isabstracttype(U)
            push!(notes, :package_abstract)
            return concrete_subtypes(A, mods, notes, depth)
        elseif A isa UnionAll
            push!(notes, :struct_parameters_filled)
            return Any[fill_parameters(A, mods, notes, depth + 1)]
        end
    end
    A isa Type && Type <: A && return Any[]
    push!(notes, :no_stand_in)
    Any[]
end

const MAX_COMBINATIONS = 8

"""
Concrete signatures for method `m`: stand-ins for generic arguments and type variables.
Returns signatures and notes; arguments without stand-in keep their declared type.
"""
function stand_in_signatures(m::Method, mods::Set{Module})::Tuple{Vector{Any}, Vector{Symbol}}
    notes = Symbol[]
    sig = m.sig
    # Substitute type variables first, outermost first.
    vars = TypeVar[]
    body = sig
    while body isa UnionAll
        push!(vars, body.var); body = body.body
    end
    choices = Vector{Any}[]
    for tv in vars
        c = typevar_candidates(tv, mods, notes, 0)
        push!(choices, isempty(c) ? Any[tv] : c)
    end
    sigs = Any[]
    for combo in Iterators.take(Iterators.product(choices...), MAX_COMBINATIONS)
        inst = instantiate(sig, vars, collect(Any, combo))
        inst === nothing && continue
        append!(sigs, expand_arguments(inst, mods, notes))
        length(sigs) >= MAX_COMBINATIONS && break
    end
    length(sigs) > MAX_COMBINATIONS && resize!(sigs, MAX_COMBINATIONS)
    sigs, notes
end

"Substitute chosen values for type variables; free variables stay wrapped."
function instantiate(sig, vars::Vector{TypeVar}, vals::Vector{Any})
    body = Base.unwrap_unionall(sig)
    free = TypeVar[]
    for (tv, v) in zip(vars, vals)
        if v isa TypeVar
            push!(free, tv)
        else
            body = try
                substitute(body, tv, v)
            catch
                return nothing
            end
        end
    end
    foldr((tv, b) -> UnionAll(tv, b), free; init = body)
end

substitute(T, tv::TypeVar, v) = ccall(:jl_instantiate_unionall, Any, (Any, Any), UnionAll(tv, T), v)

"Replace each abstract argument of tuple signature by its stand-in candidates."
function expand_arguments(sig, mods::Set{Module}, notes::Vector{Symbol})::Vector{Any}
    body = Base.unwrap_unionall(sig)
    body isa DataType || return Any[sig]
    params = collect(Any, body.parameters)
    options = Vector{Any}[]
    for (i, P) in enumerate(params)
        if i == 1 || P isa TypeVar || (P isa Type && isconcretetype(P)) || Base.isvarargtype(P)
            push!(options, Any[P])
        else
            c = argument_candidates(P, mods, notes)
            push!(options, isempty(c) ? Any[P] : c)
        end
    end
    out = Any[]
    for combo in Iterators.take(Iterators.product(options...), MAX_COMBINATIONS)
        t = try
            Base.rewrap_unionall(Tuple{combo...}, sig)
        catch
            continue
        end
        push!(out, t)
    end
    out
end

end
