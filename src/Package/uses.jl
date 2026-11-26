"""Argument a value of lowered code comes from: position, or field name of closure object."""
const Origin = Union{Int, Symbol}

"""Argument uses of one method during `argument_uses`, by position and by captured field name."""
const Uses = Dict{Origin, ArgumentUse}

"""Use without need: start of join (`record!`)."""
const NO_USE = ArgumentUse(Any[])

"""
Locals of one lowered body, by slot: values each gets (`assigned`), origins (`Origin`) each holds, joined over every
value it gets, and value of each constant local (`constants`, see `constant_value`), `#self#` included. `body_locals`
builds index once per body, so slot read scans no statement.
"""
struct Locals
    assigned::Dict{Int, Vector{Any}}
    origins::Dict{Int, Vector{Origin}}
    constants::Dict{Int, Some{Any}}
end

"""
Origins (`Origin`) value `operand` of lowered `code` can hold, for method with `nargs` arguments: argument or field of
closure object (`getfield(#self#, :name)`). Join ignores order: local (slot past arguments) holds origins of every
value it gets (`Locals`).
"""
function origins(code::AbstractVector{Any}, nargs::Integer, locals::Locals, @nospecialize(operand::Any))::Vector{Origin}
    operand isa Core.SSAValue && (operand = code[operand.id])
    # Lowering copies argument into local before body assigns it; slot 1 is callee.
    operand isa Core.SlotNumber && return operand.id > nargs ? get(locals.origins, operand.id, Origin[]) : operand.id >= 2 ? Origin[operand.id - 1] : Origin[]
    operand isa Expr || return Origin[]
    (operand.head === :call && length(operand.args) == 3 && lowered_value(code, operand.args[1]) === getfield) || return Origin[]
    field = operand.args[3]
    return operand.args[2] == Core.SlotNumber(1) && field isa QuoteNode && field.value isa Symbol ? Origin[field.value] : Origin[]
end

"""
`Locals` of lowered `code` of `method`: origins join over assignments until none grows. `#self#` (slot 1) is constant
when function type of `method` is singleton: default-argument method calls own function through it.
"""
function body_locals(code::AbstractVector{Any}, method::Method)::Locals
    locals = Locals(Dict{Int, Vector{Any}}(), Dict{Int, Vector{Origin}}(), Dict{Int, Some{Any}}())
    self = first(Facts.tuple_parameters(method.sig))
    Base.issingletontype(self) && (locals.constants[1] = Some{Any}(self.instance))
    nargs = Int(method.nargs)
    for statement in code
        statement isa Expr || continue
        target = statement.head === :(=) ? statement.args[1] : nothing
        target isa Core.SlotNumber && push!(get!(Vector{Any}, locals.assigned, target.id), statement.args[2])
    end
    # Statement order: local read before its one assignment (cycle `T = Vector{T}` too) counts as not constant.
    for statement in code
        statement isa Expr || continue
        target = statement.head === :(=) ? statement.args[1] : nothing
        target isa Core.SlotNumber || continue
        length(locals.assigned[target.id]) == 1 || continue
        found = constant_value(code, locals, statement.args[2])
        isnothing(found) || (locals.constants[target.id] = found)
    end
    grown = true
    while grown
        grown = false
        for (slot, values) in locals.assigned, assigned in values
            known = get!(Vector{Origin}, locals.origins, slot)
            fresh = setdiff(origins(code, nargs, locals, assigned), known)
            isempty(fresh) || (append!(known, fresh); grown = true)
        end
    end
    return locals
end

"""Declared type of argument `origin` of `method`: tuple for vararg argument; `nothing` for closure field."""
function declared_type(method::Method, origin::Origin)::Union{Nothing, Type}
    origin isa Int || return nothing
    parameters = Facts.tuple_parameters(method.sig)
    length(parameters) > origin || return nothing
    parameter = parameters[origin + 1]
    return Base.rewrap_unionall(Base.isvarargtype(parameter) ? Tuple{parameter} : parameter, method.sig)
end

"""
Known type of `operand` of lowered `code` of `method`: declared type of its one origin (`held`), literal, value of
constant global, or declared type of other global; else `Any`.
"""
function operand_type(code::AbstractVector{Any}, method::Method, @nospecialize(operand::Any), held::AbstractVector{<:Origin})::Type
    declared = length(held) == 1 ? declared_type(method, only(held)) : nothing
    isnothing(declared) || return declared
    operand isa Core.SSAValue && (operand = code[operand.id])
    operand isa QuoteNode && return Core.Typeof(operand.value)
    operand isa Union{Core.SlotNumber, Expr} && return Any
    operand isa GlobalRef || return Core.Typeof(operand)
    isdefined(operand.mod, operand.name) || return Any
    # Body can rebind non-constant global to value of other type.
    return isconst(operand.mod, operand.name) ? Core.Typeof(getglobal(operand.mod, operand.name)) : Core.get_binding_type(operand.mod, operand.name)
end

"""Call of statement `index` of lowered `code`: right side of assignment, or statement itself."""
function statement_call(code::AbstractVector{Any}, index::Integer)::Any
    statement = code[index]
    return statement isa Expr && statement.head === :(=) ? statement.args[2] : statement
end

"""Whether statement `index` of lowered `code` is splat call (`Core._apply_iterate`): `lowered_calls` keeps leading operands only."""
function splat_call(code::AbstractVector{Any}, index::Integer)::Bool
    call = statement_call(code, index)
    return call isa Expr && lowered_value(code, call.args[1]) === Core._apply_iterate
end

"""Whether argument `position` of call to `method` lands in its vararg parameter."""
vararg_position(method::Method, position::Integer)::Bool = (parameters = Facts.tuple_parameters(method.sig); Base.isvarargtype(last(parameters)) && position >= length(parameters) - 1)

"""
Value of `operand` of lowered `code` on every run, when constant: constant global, `Module.name` of constant in constant
module, literal, local assigned once, or type application of constant values. `nothing` for other operand: argument,
closure, call result, static parameter, non-constant global. Local reads `locals.constants`.
"""
function constant_value(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any))::Union{Nothing, Some{Any}}
    operand isa Core.SSAValue && return constant_value(code, locals, code[operand.id])
    operand isa Core.SlotNumber && return get(locals.constants, operand.id, nothing)
    operand isa QuoteNode && return Some{Any}(operand.value)
    operand isa GlobalRef && return isdefined(operand.mod, operand.name) && isconst(operand.mod, operand.name) ? Some{Any}(getglobal(operand.mod, operand.name)) : nothing
    operand isa Expr || return Some{Any}(operand)
    operand.head === :call || return nothing
    known = Union{Nothing, Some{Any}}[constant_value(code, locals, part) for part in operand.args]
    any(isnothing, known) && return nothing
    (callee, parts...) = Any[something(part) for part in known]
    callee === Core.apply_type && return try
        Some{Any}(Core.apply_type(parts...))
    catch error
        # Builtin `apply_type` rejects bad parameter count or kind; it runs no package code.
        error isa Union{TypeError, ErrorException} ? nothing : rethrow()
    end
    # Lowering turns `Base.f` into `getproperty(Base, :f)`.
    (callee === getproperty && length(parts) == 2 && parts[1] isa Module && parts[2] isa Symbol) || return nothing
    (owner, name) = parts
    return isdefined(owner, name) && isconst(owner, name) ? Some{Any}(getglobal(owner, name)) : nothing
end

"""Type `new` operand `operand` of lowered `code` builds: global, or `apply_type` of global, as closure over typed captures."""
function built_type(code::AbstractVector{Any}, @nospecialize(operand::Any))::Any
    operand isa Core.SSAValue && (operand = code[operand.id])
    operand isa Expr && operand.head === :call && lowered_value(code, operand.args[1]) === Core.apply_type && (operand = operand.args[2])
    return lowered_value(code, operand)
end

"""Join `use` into entry `key` of `uses`; return whether entry grew."""
function record!(uses::Uses, key::Origin, use::ArgumentUse)::Bool
    old = get(uses, key, NO_USE).stored
    stored = union(old, use.stored)
    length(stored) == length(old) && return false
    uses[key] = ArgumentUse(stored)
    return true
end

"""
Uses that struct `type` gives values `new` or default constructor stores into its fields, by field: declared field
type, or `nothing` for field typed by parameter. Closure and other module's type give `nothing`.
"""
function field_uses(@nospecialize(type::Any), modules::AbstractSet{Module})::Union{Nothing, Vector{Union{Nothing, ArgumentUse}}}
    wrapper = Base.unwrap_unionall(type)
    wrapper isa DataType || return nothing
    (wrapper.name.module in modules && isstructtype(wrapper) && !(wrapper <: Function)) || return nothing
    return Union{Nothing, ArgumentUse}[Base.has_free_typevars(field) ? nothing : ArgumentUse(Any[field]) for field in fieldtypes(wrapper)]
end

"""Push to `fixed` use (`field_uses`) of each `held` operand origin constructor of `type` stores, when it takes one per field."""
function push_field_uses!(fixed::AbstractVector{Tuple{Origin, ArgumentUse}}, @nospecialize(type::Any), held::AbstractVector{<:AbstractVector{Origin}}, modules::AbstractSet{Module})::Nothing
    fields = field_uses(type, modules)
    (isnothing(fields) || length(fields) != length(held)) && return nothing
    for (use, reached) in zip(fields, held), origin in reached
        isnothing(use) || push!(fixed, (origin, use))
    end
    return nothing
end

"""
Steps of `method` with lowered `code` for `argument_uses`: fixed uses of operand origins, and links from origin to entry
`key` of other methods. `targets` gives package methods callee value can run.
"""
function use_steps(code::AbstractVector{Any}, method::Method, targets::Function, closures::AbstractDict{Core.TypeName, <:AbstractVector{Method}}, modules::AbstractSet{Module})::Tuple{Vector{Tuple{Origin, ArgumentUse}}, Vector{Tuple{Origin, Vector{Method}, Int}}}
    fixed, links = Tuple{Origin, ArgumentUse}[], Tuple{Origin, Vector{Method}, Int}[]
    nargs, locals = Int(method.nargs), body_locals(code, method)
    for (index, callee, head, operands) in lowered_calls(code)
        held = Vector{Origin}[origins(code, nargs, locals, operand) for operand in operands]
        types = Type[operand_type(code, method, operand, origins) for (operand, origins) in zip(operands, held)]
        callee === Core.kwcall && length(operands) >= 2 && ((callee, head, operands, held, types) = (lowered_value(code, operands[2]), operands[2], operands[3:end], held[3:end], types[3:end]))
        push_field_uses!(fixed, callee, held, modules)
        constant = constant_value(code, locals, head)
        # Open callee and splat hide callee or its positions (`ArgumentUse` blind spots).
        (isnothing(constant) || splat_call(code, index)) && continue
        candidates = targets(something(constant))
        # Broadcast over `Ref{Type}`: closure over signature, or `Ref(signature)`, compiles once per signature (`perf.jl`).
        callees = candidates[typeintersect.(Ref{Type}(Tuple{Any, types...}), Type[target.sig for target in candidates]) .!== Union{}]
        for (position, reached) in pairs(held), origin in reached
            exact = filter(target -> !vararg_position(target, position), callees)
            isempty(exact) || push!(links, (origin, exact, position))
        end
    end
    for statement in code
        built = statement isa Expr && statement.head === :(=) ? statement.args[2] : statement
        built isa Expr || continue
        built.head === :new || continue
        type, held = built_type(code, built.args[1]), Vector{Origin}[origins(code, nargs, locals, operand) for operand in built.args[2:end]]
        push_field_uses!(fixed, type, held, modules)
        wrapper = Base.unwrap_unionall(type)
        wrapper isa DataType || continue
        haskey(closures, wrapper.name) || continue
        names = fieldnames(wrapper)
        for (index, reached) in pairs(held), origin in reached
            index > length(names) || push!(links, (origin, closures[wrapper.name], -index))
        end
    end
    return fixed, links
end

"""
Argument uses of lowered `bodies` (`lowered_bodies`) of package `modules` that need declared container type
(`ArgumentUse`), by method and position. Passes repeat until no use grows: each joins stores of package callee
arguments, including keyword bodies (`Core.kwcall`), and of closure fields into operands that reach them.
"""
function argument_uses(bodies::AbstractVector{<:Tuple{Method, AbstractVector{Any}, Type}}, modules::AbstractSet{Module})::IdDict{Method, Dict{Int, ArgumentUse}}
    exact, inexact_keys, inexact_methods, closures = IdDict{Type, Vector{Method}}(), Type[], Method[], IdDict{Core.TypeName, Vector{Method}}()
    for (method, _, key) in bodies
        if isconcretetype(key)
            push!(get!(Vector{Method}, exact, key), method)
        else
            push!(inexact_keys, key)
            push!(inexact_methods, method)
        end
        wrapper = Base.unwrap_unionall(key)
        wrapper isa DataType && wrapper <: Function && push!(get!(Vector{Method}, closures, wrapper.name), method)
    end
    function targets(@nospecialize(callee::Any))::Vector{Method}
        isnothing(callee) && return Method[]
        type = Core.Typeof(callee)
        # Broadcast: closure over callee type compiles once per type (`perf.jl`).
        return [get(exact, type, Method[]); inexact_methods[Ref{Type}(type) .<: inexact_keys]]
    end
    uses = IdDict{Method, Uses}(method => Uses() for (method, _, _) in bodies)
    links = Tuple{Uses, Origin, Vector{Method}, Int}[]
    for (method, code, _) in bodies
        fixed, own = use_steps(code, method, targets, closures, modules)
        foreach(((found, use),) -> record!(uses[method], found, use), fixed)
        append!(links, [(uses[method], found, callees, key) for (found, callees, key) in own])
    end
    grown = true
    while grown
        grown = false
        for (into, key, callees, link) in links, callee in callees
            # Negative link names closure field by position.
            use = get(uses[callee], link > 0 ? link : fieldnames(Base.unwrap_unionall(callee_type(callee)))[-link], nothing)
            isnothing(use) || (grown |= record!(into, key, use))
        end
    end
    return IdDict{Method, Dict{Int, ArgumentUse}}(method => Dict{Int, ArgumentUse}(key => use for (key, use) in found if key isa Int) for (method, found) in uses if any(key -> key isa Int, keys(found)))
end
