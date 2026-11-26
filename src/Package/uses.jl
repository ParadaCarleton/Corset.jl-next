"""Argument a value of lowered code comes from: position, or field name of closure object; and whether value is its element."""
const Origin = Tuple{Union{Int, Symbol}, Bool}

"""Argument uses of one method during `argument_uses`, by position and by captured field name."""
const Uses = Dict{Union{Int, Symbol}, ArgumentUse}

"""Use without need: start of join (`record!`)."""
const NO_USE = ArgumentUse(false, false, Any[])

"""Use of argument that body resizes (`RESIZE_FUNCTIONS`)."""
const RESIZED = ArgumentUse(true, false, Any[])

"""Use of argument whose callee or callee position is unknown: open callee, splat, vararg, keyword value. Every resize counts."""
const UNKNOWN = ArgumentUse(true, true, Any[])

"""
Locals of one lowered body, by slot: values each gets (`assigned`), origins (`Origin`) each holds, joined over every
value it gets, and value of each constant local (`constants`, see `constant_value`), `#self#` included. `body_locals`
builds index once per body, so slot read scans no statement.
"""
struct Locals
    assigned::Dict{Int, Vector{Any}}
    origins::Dict{Int, Vector{Origin}}
    constants::Dict{Int, Some}
end

"""
Origins (`Origin`) value `operand` of lowered `code` can hold, for method with `nargs` arguments: argument, field of
closure object (`getfield(#self#, :name)`), or element `getindex` or `for` loop reads from either. Join ignores order:
local (slot past arguments) holds origins of every value it gets (`Locals`).
"""
function origins(code::AbstractVector{Any}, nargs::Integer, locals::Locals, @nospecialize(operand::Any))::Vector{Origin}
    operand isa Core.SSAValue && (operand = code[operand.id])
    # Lowering copies argument into local before body assigns it; slot 1 is callee.
    operand isa Core.SlotNumber && return operand.id > nargs ? get(locals.origins, operand.id, Origin[]) : operand.id >= 2 ? [(operand.id - 1, false)] : Origin[]
    operand isa Expr || return Origin[]
    (operand.head === :call && length(operand.args) >= 2) || return Origin[]
    callee, subject = lowered_value(code, operand.args[1]), operand.args[2]
    if callee === getfield && length(operand.args) == 3
        field = operand.args[3]
        subject == Core.SlotNumber(1) && field isa QuoteNode && field.value isa Symbol && return [(field.value, false)]
        # `for x in X` reads `x` as field 1 of `iterate(X, ...)` result.
        field === 1 || return Origin[]
        inner = iterated(code, nargs, locals, subject)
    elseif callee === getindex
        inner = origins(code, nargs, locals, subject)
    else
        return Origin[]
    end
    return Origin[(key, true) for (key, element) in inner if !element]
end

"""Origins (`origins`) of collections local `state` iterates: values of its assignments `state = iterate(X, ...)`."""
function iterated(code::AbstractVector{Any}, nargs::Integer, locals::Locals, @nospecialize(state::Any))::Vector{Origin}
    state isa Core.SSAValue && (state = code[state.id])
    found = Origin[]
    state isa Core.SlotNumber || return found
    for call in get(locals.assigned, state.id, Any[])
        call isa Expr || continue
        (call.head === :call && length(call.args) >= 2 && lowered_value(code, call.args[1]) === iterate) || continue
        union!(found, origins(code, nargs, locals, call.args[2]))
    end
    return found
end

"""
`Locals` of lowered `code` of `method`: origins join over assignments until none grows. `#self#` (slot 1) is constant
when function type of `method` is singleton: default-argument method calls own function through it.
"""
function body_locals(code::AbstractVector{Any}, method::Method)::Locals
    locals = Locals(Dict{Int, Vector{Any}}(), Dict{Int, Vector{Origin}}(), Dict{Int, Some}())
    self = first(Facts.tuple_parameters(method.sig))
    Base.issingletontype(self) && (locals.constants[1] = Some(self.instance))
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

"""
Statement or value `operand` of lowered `code` stands for, through statements and chains of locals assigned once.
`nothing` for argument, local assigned more than once, and cycle of locals (`c = c`).
"""
function resolved(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any))::Any
    # Chain without cycle visits each local once.
    for _ in 0:length(locals.assigned)
        operand isa Core.SSAValue && (operand = code[operand.id])
        operand isa Core.SlotNumber || return operand
        assigned = get(locals.assigned, operand.id, nothing)
        isnothing(assigned) && return nothing
        length(assigned) == 1 || return nothing
        operand = only(assigned)
    end
    return nothing
end

"""`lowered_value` of `operand` of lowered `code`, with locals read from `locals` index."""
local_value(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any))::Any = lowered_value(code, resolved(code, locals, operand))

"""Whether `operand` of lowered `code` is function or type: global, type application or closure object (`new`)."""
function callable(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any))::Bool
    local_value(code, locals, operand) isa Base.Callable && return true
    operand isa Core.SSAValue || return false
    statement = code[operand.id]
    statement isa Expr || return false
    return statement.head === :new || (statement.head === :call && lowered_value(code, statement.args[1]) === Core.apply_type)
end

"""Resizing functions with method that takes function first and collection second: `filter!(f, a)`, `get!(f, d, k)`."""
const FUNCTION_FIRST = Base.IdSet{Any}(Any[filter!, unique!, merge!, mergewith!, get!])

"""
Positions of `operands` of resizing call to `callee` in lowered `code` of `method` that can hold collection call resizes.
`FUNCTION_FIRST` call with two operands or more gives both when first operand (`held` origins) is of unknown kind.
"""
function resized_positions(code::AbstractVector{Any}, locals::Locals, method::Method, @nospecialize(callee::Any), operands::AbstractVector, held::AbstractVector{<:AbstractVector{Origin}})::UnitRange{Int}
    isempty(operands) && return 1:0
    (callee in FUNCTION_FIRST && length(operands) >= 2) || return 1:1
    callable(code, locals, first(operands)) && return 2:2
    declared = length(first(held)) == 1 ? declared_type(method, only(first(held))) : nothing
    isnothing(declared) && return 1:2
    declared <: Base.Callable && return 2:2
    return declared <: Union{AbstractArray, AbstractDict, AbstractSet} ? (1:1) : (1:2)
end

"""
Declared type of argument `origin` of `method`: tuple for vararg argument; for element, dictionary value or `eltype`.
`nothing` for closure field.
"""
function declared_type(method::Method, origin::Origin)::Union{Nothing, Type}
    (position, element) = origin
    parameters = Facts.tuple_parameters(method.sig)
    position isa Int || return nothing
    length(parameters) > position || return nothing
    parameter = parameters[position + 1]
    declared = Base.rewrap_unionall(Base.isvarargtype(parameter) ? Tuple{parameter} : parameter, method.sig)
    return element ? element_type(declared) : declared
end

"""
Type `getindex` reads from collection of `declared` type: value of `AbstractDict` supertype, element of `AbstractArray`
supertype, else `Any`. Supertypes give it: `eltype` and `valtype` could run package code.
"""
function element_type(declared::Type)::Type
    body = Base.unwrap_unionall(declared)
    while body isa DataType && body !== Any
        index = body.name === Base.typename(AbstractDict) ? 2 : body.name === Base.typename(AbstractArray) ? 1 : 0
        index == 0 || return body.parameters[index] isa Type ? body.parameters[index] : Any
        body = supertype(body)
    end
    return Any
end

"""
Known type of `operand` of lowered `code` of `method`: declared type of its one origin (`held`), literal, value of
constant global, or declared type of other global; else `Any`.
"""
function operand_type(code::AbstractVector{Any}, method::Method, @nospecialize(operand::Any), held::AbstractVector{<:Origin})::Type
    # Element origin can be slice (`x[1:2]`): its type is unknown.
    declared = length(held) == 1 && !last(only(held)) ? declared_type(method, only(held)) : nothing
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

"""Operands of splat call at statement `index` of lowered `code`: elements of `tuple(...)` parts, and other parts."""
function splat_operands(code::AbstractVector{Any}, index::Integer)::Vector{Any}
    call = statement_call(code, index)
    found = Any[]
    call isa Expr || return found
    # Operands: `_apply_iterate`, `iterate`, callee, parts.
    for part in call.args[4:end]
        tuple = part isa Core.SSAValue ? code[part.id] : nothing
        if tuple isa Expr && tuple.head === :call && lowered_value(code, tuple.args[1]) === Core.tuple
            append!(found, tuple.args[2:end])
        else
            push!(found, part)
        end
    end
    return found
end

"""Values of keyword arguments `names` operand of `Core.kwcall` in lowered `code` holds: `NamedTuple{names}(tuple(values...))`."""
function keyword_values(code::AbstractVector{Any}, @nospecialize(names::Any))::Vector{Any}
    built = names isa Core.SSAValue ? code[names.id] : nothing
    built isa Expr || return Any[]
    (built.head === :call && length(built.args) == 2) || return Any[]
    values = built.args[2] isa Core.SSAValue ? code[built.args[2].id] : nothing
    return values isa Expr && values.head === :call && lowered_value(code, values.args[1]) === Core.tuple ? values.args[2:end] : Any[]
end

"""Whether argument `position` of call to `method` lands in its vararg parameter."""
vararg_position(method::Method, position::Integer)::Bool = (parameters = Facts.tuple_parameters(method.sig); Base.isvarargtype(last(parameters)) && position >= length(parameters) - 1)

"""
Value of `operand` of lowered `code` on every run, when constant: constant global, `Module.name` of constant in constant
module, literal, local assigned once, or type application of constant values. `nothing` for other operand: argument,
closure, call result, static parameter, non-constant global. Local reads `locals.constants`.
"""
function constant_value(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any))::Union{Nothing, Some}
    operand isa Core.SSAValue && return constant_value(code, locals, code[operand.id])
    operand isa Core.SlotNumber && return get(locals.constants, operand.id, nothing)
    operand isa QuoteNode && return Some(operand.value)
    operand isa GlobalRef && return isdefined(operand.mod, operand.name) && isconst(operand.mod, operand.name) ? Some(getglobal(operand.mod, operand.name)) : nothing
    operand isa Expr || return Some(operand)
    operand.head === :call || return nothing
    known = Union{Nothing, Some}[constant_value(code, locals, part) for part in operand.args]
    any(isnothing, known) && return nothing
    (callee, parts...) = Any[something(part) for part in known]
    callee === Core.apply_type && return try
        Some(Core.apply_type(parts...))
    catch error
        # Builtin `apply_type` rejects bad parameter count or kind; it runs no package code.
        error isa Union{TypeError, ErrorException} ? nothing : rethrow()
    end
    # Lowering turns `Base.f` into `getproperty(Base, :f)`.
    (callee === getproperty && length(parts) == 2 && parts[1] isa Module && parts[2] isa Symbol) || return nothing
    (owner, name) = parts
    return isdefined(owner, name) && isconst(owner, name) ? Some(getglobal(owner, name)) : nothing
end

"""Package methods function operand `operand` of lowered `code` can run: closure object it builds, or `targets` of its value."""
function function_methods(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any), targets::Function, closures::AbstractDict{Core.TypeName, <:AbstractVector{Method}})::Vector{Method}
    built = resolved(code, locals, operand)
    built isa Expr || return targets(local_value(code, locals, operand))
    built.head === :new || return targets(local_value(code, locals, operand))
    wrapper = Base.unwrap_unionall(built_type(code, built.args[1]))
    return wrapper isa DataType ? Vector{Method}(get(closures, wrapper.name, Method[])) : Method[]
end

"""Type `new` operand `operand` of lowered `code` builds: global, or `apply_type` of global, as closure over typed captures."""
function built_type(code::AbstractVector{Any}, @nospecialize(operand::Any))::Any
    operand isa Core.SSAValue && (operand = code[operand.id])
    operand isa Expr && operand.head === :call && lowered_value(code, operand.args[1]) === Core.apply_type && (operand = operand.args[2])
    return lowered_value(code, operand)
end

"""
Join `use` into entry `key` of `uses`: use of element (`element`) adds its resizes to elements, other use adds all.
Element origin can be slice, whose elements are elements of argument. Return whether entry changed.
"""
function record!(uses::Uses, key::Union{Integer, Symbol}, use::ArgumentUse, element::Bool)::Bool
    old = get(uses, key, NO_USE)
    new = element ? ArgumentUse(old.resized, old.elements_resized || use.resized || use.elements_resized, old.stored) :
        ArgumentUse(old.resized || use.resized, old.elements_resized || use.elements_resized, union(old.stored, use.stored))
    (new.resized, new.elements_resized, length(new.stored)) == (old.resized, old.elements_resized, length(old.stored)) && return false
    uses[key] = new
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
    return Union{Nothing, ArgumentUse}[Base.has_free_typevars(field) ? nothing : ArgumentUse(false, false, Any[field]) for field in fieldtypes(wrapper)]
end

"""Push to `fixed` use (`field_uses`) of each `held` operand origin constructor of `type` stores, when it takes one per field."""
function push_field_uses!(fixed::AbstractVector{Tuple{Origin, ArgumentUse}}, @nospecialize(type::Any), held::AbstractVector{<:AbstractVector{Origin}}, modules::AbstractSet{Module})::Nothing
    fields = field_uses(type, modules)
    (isnothing(fields) || length(fields) != length(held)) && return nothing
    for (use, reached) in zip(fields, held), origin in reached
        isnothing(use) || last(origin) || push!(fixed, (origin, use))
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
        if callee in RESIZE_FUNCTIONS || callee === get!
            for position in resized_positions(code, locals, method, callee, operands, held), origin in held[position]
                push!(fixed, (origin, RESIZED))
            end
        elseif callee === setindex! && !isempty(held)
            # Array element write keeps size; dictionary write can add key.
            for origin in first(held)
                declared = declared_type(method, origin)
                !isnothing(declared) && typeintersect(declared, AbstractDict) !== Union{} && push!(fixed, (origin, RESIZED))
            end
        end
        types = Type[operand_type(code, method, operand, origins) for (operand, origins) in zip(operands, held)]
        keywords = callee === Core.kwcall && length(operands) >= 2 ? keyword_values(code, first(operands)) : Any[]
        callee === Core.kwcall && length(operands) >= 2 && ((callee, head, operands, held, types) = (lowered_value(code, operands[2]), operands[2], operands[3:end], held[3:end], types[3:end]))
        push_field_uses!(fixed, callee, held, modules)
        splat = splat_call(code, index)
        hidden = splat ? [splat_operands(code, index); keywords] : keywords
        constant = constant_value(code, locals, head)
        if isnothing(constant)
            # Open callee can run any function with any operand.
            for operand in [operands; hidden], origin in origins(code, nargs, locals, operand)
                push!(fixed, (origin, UNKNOWN))
            end
            continue
        end
        callee = something(constant)
        # Callee methods whose signature can take known operand types; splat call has unknown operands after them.
        call = splat ? Tuple{Any, types..., Vararg{Any}} : Tuple{Any, types...}
        callees = Method[target for target in targets(callee) if typeintersect(call, target.sig) !== Union{}]
        if isempty(callees)
            # Higher-order call (`foreach(f, xs)`) can pass other operands to function operand: link 0 reaches any position.
            for (position, operand) in pairs(operands)
                value = local_value(code, locals, operand)
                resizing = value in RESIZE_FUNCTIONS || value === get!
                functions = resizing ? Method[] : function_methods(code, locals, operand, targets, closures)
                (resizing || !isempty(functions)) || continue
                for (other, reached) in pairs(held), origin in reached
                    other == position && continue
                    if resizing
                        push!(fixed, (origin, UNKNOWN))
                    else
                        push!(links, (origin, functions, 0))
                    end
                end
            end
            continue
        end
        # Splat and keyword value hide callee position.
        for operand in hidden, origin in origins(code, nargs, locals, operand)
            push!(fixed, (origin, UNKNOWN))
        end
        splat && continue
        for (position, reached) in pairs(held), origin in reached
            any(target -> vararg_position(target, position), callees) && push!(fixed, (origin, UNKNOWN))
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
(`ArgumentUse`), by method and position. Passes repeat until no use grows: each joins uses of package callee arguments,
including keyword bodies (`Core.kwcall`), and of closure fields into operands that reach them.
"""
function argument_uses(bodies::AbstractVector{<:Tuple{Method, AbstractVector{Any}, Type}}, modules::AbstractSet{Module})::IdDict{Method, Dict{Int, ArgumentUse}}
    exact, inexact, closures = IdDict{Type, Vector{Method}}(), Tuple{Type, Method}[], IdDict{Core.TypeName, Vector{Method}}()
    for (method, _, key) in bodies
        if isconcretetype(key)
            push!(get!(Vector{Method}, exact, key), method)
        else
            push!(inexact, (key, method))
        end
        wrapper = Base.unwrap_unionall(key)
        wrapper isa DataType && wrapper <: Function && push!(get!(Vector{Method}, closures, wrapper.name), method)
    end
    function targets(@nospecialize(callee::Any))::Vector{Method}
        isnothing(callee) && return Method[]
        type = Core.Typeof(callee)
        return [get(exact, type, Method[]); Method[method for (key, method) in inexact if type <: key]]
    end
    uses = IdDict{Method, Uses}(method => Uses() for (method, _, _) in bodies)
    links = Tuple{Uses, Origin, Vector{Method}, Int}[]
    for (method, code, _) in bodies
        fixed, own = use_steps(code, method, targets, closures, modules)
        foreach(((found, use),) -> record!(uses[method], first(found), use, last(found)), fixed)
        append!(links, [(uses[method], found, callees, key) for (found, callees, key) in own])
    end
    grown = true
    while grown
        grown = false
        for (into, (key, element), callees, link) in links, callee in callees
            # Link 0 reaches any position; negative link names closure field by position.
            use = link == 0 ? (any(((entry, found),) -> entry isa Int && (found.resized || found.elements_resized), uses[callee]) ? UNKNOWN : nothing) :
                get(uses[callee], link > 0 ? link : fieldnames(Base.unwrap_unionall(callee_type(callee)))[-link], nothing)
            isnothing(use) || (grown |= record!(into, key, use, element))
        end
    end
    return IdDict{Method, Dict{Int, ArgumentUse}}(method => Dict{Int, ArgumentUse}(key => use for (key, use) in found if key isa Int) for (method, found) in uses if any(key -> key isa Int, keys(found)))
end
