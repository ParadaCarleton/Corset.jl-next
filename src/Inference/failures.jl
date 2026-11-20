"""
Throw helper verdict on `callee`, with compiler edges of inferences it ran. Helper: `throw`, or function each of whose
methods throws for every argument type it declares (`error`, `rethrow`, `Base.Enums.enum_argument_error`). Fallback
method that throws for one missing interface does not make function helper.
"""
function throw_helper(@nospecialize(callee::Any))::Tuple{Bool, Vector{Any}}
    callee === throw && return true, Any[]
    found, edges = methods(callee), Any[]
    isempty(found) && return false, edges
    for method in found
        inferred = infer(method, method.sig)
        isnothing(inferred) && return false, edges
        append!(edges, inferred[4])
        inferred[3] === Union{} || return false, edges
    end
    return true, edges
end

"""
Callable value of inferred `type`: its singleton, or type name of constructor with unknown parameters
(`Type{Point{T}} where T` gives `Point`); else `nothing`.
"""
function callable(@nospecialize(type::Any))::Any
    singleton = CC.singleton_type(type)
    !isnothing(singleton) && return singleton
    bare = Base.unwrap_unionall(CC.widenconst(type))
    bare isa DataType || return nothing
    bare.name === Base.typename(Type) || return nothing
    constructed = Base.unwrap_unionall(only(bare.parameters))
    return constructed isa DataType ? constructed.name.wrapper : nothing
end

"""
Function or type `call` in typed `code` (lowered or IR) calls, when inference knows it: inner callee of splatted call
(`Core._apply_iterate`) and keyword call (`Core.kwcall`); else `nothing`.
"""
function called(code::Union{Core.CodeInfo, CC.IRCode}, call::Expr, parameters::Vector{CC.VarState})::Any
    callee = callable(code_argextype(call.args[1], code, parameters))
    callee in (Core._apply_iterate, Core.kwcall) && length(call.args) >= 3 && return callable(code_argextype(call.args[3], code, parameters))
    return callee
end

"""Whether `call` dispatches to one method that analyzed `files` define; its own frame reports failure inside it."""
function package_call(code::Core.CodeInfo, call::Expr, parameters::Vector{CC.VarState}, files::Dict{String, SyntaxFile})::Bool
    types = Any[CC.widenconst(code_argextype(argument, code, parameters)) for argument in call.args]
    matches = Base._methods_by_ftype(Tuple{types...}, 1, Base.get_world_counter())
    return matches isa Vector && length(matches) == 1 && haskey(files, string(only(matches).method.file))
end

"""
Inferred type on `signature` of statement `index` of code of `method` on `own`, `Union{}` when it never returns, `nothing`
without code. Generated code differs per signature, so its index names no statement on other signature: `nothing` too.
Adds compiler edges of inference to `edges`.
"""
function statement_type!(edges::Vector{Any}, method::Method, own::Type, signature::Type, index::Int)::Union{Nothing, Type}
    Base.hasgenerator(method) && signature != own && return nothing
    inferred = infer(method, signature)
    isnothing(inferred) && return nothing
    append!(edges, inferred[4])
    return CC.widenconst(inferred[2].ssavaluetypes[index])
end

"""Name of called function; called type as `scope` prints it (`Vector{Float64}`); text of other callable value."""
callee_text(@nospecialize(callee::Any), scope::Module)::String = callee isa Function ? string(nameof(callee)) : callee isa Type ? sprint(show, callee; context = :module => scope) : repr(callee)

"""
Reached call statements of typed `code` that never return, with callee that inference knows (`called`): statement
index, call and callee. `parameters` are static parameters of instance of `code`.
"""
function never_returning(code::Core.CodeInfo, parameters::Vector{CC.VarState})::Vector{Tuple{Int, Expr, Any}}
    found = Tuple{Int, Expr, Any}[]
    for (index, statement) in enumerate(code.code)
        # Unreached statement is wrapped in `Core.Const`, so it is no call.
        call = statement_call(statement)
        (isnothing(call) || code.ssavaluetypes[index] !== Union{}) && continue
        callee = called(code, call, parameters)
        isnothing(callee) || push!(found, (index, call, callee))
    end
    return found
end

"""
Call statements of `typed` that never return, by statement index: fact, or blind spot where call returns once stand-ins
become their models. Skips unknown callees and throw helpers. Also gives index of each call that fails on stand-in only:
stand-in cuts (`cuts!`). Call of package method in `files` gets no fact or spot: its own frame reports failure inside it.
Adds compiler edges of inferences it runs to `edges`; `helpers` caches throw-helper verdicts with their edges.
"""
function failures!(edges::Vector{Any}, helpers::IdDict{Any, Tuple{Bool, Vector{Any}}}, typed::TypedCode, files::Dict{String, SyntaxFile})::Tuple{Vector{Pair{Int, Union{FailingCall, BlindSpot}}}, Vector{Int}}
    found, failing = Pair{Int, Union{FailingCall, BlindSpot}}[], Int[]
    method, code, signature = typed.site.method, typed.code, typed.signature
    parameters = CC.sptypes_from_meth_instance(something(instance(method, signature)))
    for (index, call, callee) in never_returning(code, parameters)
        helper, helper_edges = get!(() -> throw_helper(callee), helpers, callee)
        append!(edges, helper_edges)
        helper && continue
        own = package_call(code, call, parameters, files)
        # Model signature without code cannot confirm failure either, so it also counts as blind spot.
        modeled = statement_type!(edges, method, signature, StandIns.model_type(signature), index)
        if modeled !== Union{}
            push!(failing, index)
            own || push!(found, index => BlindSpot("call fails on stand-in only", typed.spans[index]))
            continue
        end
        own && continue
        confidence = statement_type!(edges, method, signature, method.sig, index) === Union{} ? Confidence.definite : Confidence.possible
        push!(found, index => FailingCall(typed.spans[index], name_span(typed.site), callee_text(callee, method.module), confidence))
    end
    return found, failing
end

"""Whether typed `statement` calls function or C code, assigned or not; stores are calls (`setfield!`, `setglobal!`)."""
effect_statement(@nospecialize(statement::Any))::Bool = (value = Widening.assigned(statement); value isa Expr && value.head in (:call, :foreigncall, :invoke))

"""Indexes of call statements typed `code` never reaches: inference wraps unreached statement in `Core.Const`."""
dead_calls(code::Core.CodeInfo)::Vector{Int} = [index for (index, statement) in enumerate(code.code) if statement isa Core.Const && effect_statement(statement.val)]

"""
Stand-in cuts of `typed` code of `method` on `signature` (`effects.md`, Stand-in cuts): dead call statements that
declared signature reaches, and `failing` calls (fail on stand-in only, `failures!`). Infers declared signature once per
method (`declared`), only for code with dead calls. Declared signature without code cannot clear dead call, so each
counts as cut; nor can generated code, whose statements differ per signature.
"""
function cuts!(declared::IdDict{Method, Union{Nothing, Core.CodeInfo}}, method::Method, signature::Type, code::Core.CodeInfo, failing::Vector{Int})::Vector{Int}
    dead = dead_calls(code)
    (isempty(dead) || signature == method.sig) && return failing
    reference = get!(() -> (result = Base.hasgenerator(method) ? nothing : infer(method, method.sig); isnothing(result) ? nothing : result[2]), declared, method)
    isnothing(reference) && return sort!([dead; failing])
    length(reference.code) == length(code.code) || error("declared and stand-in code of $method differ in length")
    return sort!([filter(index -> !(reference.code[index] isa Core.Const), dead); failing])
end
