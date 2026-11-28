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
function called(code::Union{Core.CodeInfo, CC.IRCode}, call::Expr, parameters::AbstractVector{CC.VarState})::Any
    callee = callable(code_argextype(call.args[1], code, parameters))
    callee in (Core._apply_iterate, Core.kwcall) && length(call.args) >= 3 && return callable(code_argextype(call.args[3], code, parameters))
    return callee
end

"""Whether `call` dispatches to one method that analyzed `files` define; its own frame reports failure inside it."""
function package_call(code::Core.CodeInfo, call::Expr, parameters::AbstractVector{CC.VarState}, files::AbstractDict{String, SyntaxFile})::Bool
    types = Any[CC.widenconst(code_argextype(argument, code, parameters)) for argument in call.args]
    matches = Base._methods_by_ftype(Tuple{types...}, 1, Base.get_world_counter())
    return matches isa Vector && length(matches) == 1 && haskey(files, string(only(matches).method.file))
end

"""
Throw-helper verdict with its compiler edges by callee (`throw_helper`), shared by inference threads; `lock` guards
`verdicts`. Verdicts are written and read as stored, so field types stay concrete.
"""
struct HelperVerdicts
    lock::ReentrantLock
    verdicts::IdDict{Any, Tuple{Bool, Vector{Any}}}
end

HelperVerdicts()::HelperVerdicts = HelperVerdicts(ReentrantLock(), IdDict{Any, Tuple{Bool, Vector{Any}}}())

"""
Throw helper verdict on `callee` from `helpers`, computed on first use. Inference runs outside lock: threads that race
compute same verdict, and first stored one stays.
"""
function helper_verdict!(helpers::HelperVerdicts, @nospecialize(callee::Any))::Tuple{Bool, Vector{Any}}
    known = @lock helpers.lock get(helpers.verdicts, callee, nothing)
    isnothing(known) || return known
    found = throw_helper(callee)
    return @lock helpers.lock get!(helpers.verdicts, callee, found)
end

"""
Typed code of `method` on `signature` from `codes`, inferred on first use: each signature infers once per unit, not once
per statement. Adds compiler edges of inference to `edges`; `nothing` without code.
"""
function typed_code!(codes::IdDict{Any, Union{Nothing, Core.CodeInfo}}, edges::AbstractVector{Any}, method::Method, signature::Type)::Union{Nothing, Core.CodeInfo}
    haskey(codes, signature) && return codes[signature]
    inferred = infer(method, signature)
    isnothing(inferred) || append!(edges, inferred[4])
    return codes[signature] = isnothing(inferred) ? nothing : inferred[2]
end

"""
Inferred type on `signature` of statement `index` of code of `method` on `own`, `Union{}` when it never returns, `nothing`
without code. Generated code differs per signature, so its index names no statement on other signature: `nothing` too.
`codes` keeps typed code per signature (`typed_code!`) and adds compiler edges of inference to `edges`.
"""
function statement_type!(codes::IdDict{Any, Union{Nothing, Core.CodeInfo}}, edges::AbstractVector{Any}, method::Method, own::Type, signature::Type, index::Integer)::Union{Nothing, Type}
    Base.hasgenerator(method) && signature != own && return nothing
    code = typed_code!(codes, edges, method, signature)
    return isnothing(code) ? nothing : CC.widenconst(code.ssavaluetypes[index])
end

"""Name of called function; called type as `scope` prints it (`Vector{Float64}`); text of other callable value."""
callee_text(@nospecialize(callee::Any), scope::Module)::String = callee isa Function ? string(nameof(callee)) : callee isa Type ? sprint(show, callee; context = :module => scope) : repr(callee)

"""
Reached call statements of typed `code` that never return, with callee that inference knows (`called`): statement
index, call and callee. `parameters` are static parameters of instance of `code`.
"""
function never_returning(code::Core.CodeInfo, parameters::AbstractVector{CC.VarState})::Vector{Tuple{Int, Expr, Any}}
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
Verdict on call statement `index` that never returns, with callee that inference knows (`called`). `confidence` of
failure; `nothing` when call returns once stand-ins become their models. `own` call of package method gets no fact or
spot: its own frame reports failure inside it.
"""
struct CallVerdict
    index::Int
    callee::Any
    own::Bool
    confidence::Union{Nothing, Confidence.T}
end

"""
Verdicts on call statements that never return in `output` of `method` on unit `signature` (`infer`), with compiler edges
of inferences they read. Skips unknown callees and throw helpers (`helper_verdict!`). Inference threads run it
(`infer_wave!`); package method in `files` decides `own`.
"""
function call_verdicts!(helpers::HelperVerdicts, method::Method, signature::Type, output::Output, files::AbstractDict{String, SyntaxFile})::Tuple{Vector{CallVerdict}, Vector{Any}}
    verdicts, edges, codes = CallVerdict[], Any[], IdDict{Any, Union{Nothing, Core.CodeInfo}}()
    code, parameters = output[2], CC.sptypes_from_meth_instance(output[1])
    for (index, call, callee) in never_returning(code, parameters)
        helper, helper_edges = helper_verdict!(helpers, callee)
        append!(edges, helper_edges)
        helper && continue
        own = package_call(code, call, parameters, files)
        # Model signature without code cannot confirm failure either, so it also counts as blind spot.
        if statement_type!(codes, edges, method, signature, StandIns.model_type(signature), index) !== Union{}
            push!(verdicts, CallVerdict(index, callee, own, nothing))
            continue
        end
        own && continue
        declared = statement_type!(codes, edges, method, signature, method.sig, index) === Union{}
        push!(verdicts, CallVerdict(index, callee, false, declared ? Confidence.definite : Confidence.possible))
    end
    return verdicts, edges
end

"""
Call statements of `typed` that never return, by statement index, from its `verdicts` (`call_verdicts!`): fact, or blind
spot where call returns once stand-ins become their models. Also gives index of each call that fails on stand-in only:
stand-in cuts (`cuts!`).
"""
function call_failures(typed::TypedCode, verdicts::AbstractVector{CallVerdict})::Tuple{Vector{Pair{Int, Union{FailingCall, BlindSpot}}}, Vector{Int}}
    found, failing = Pair{Int, Union{FailingCall, BlindSpot}}[], Int[]
    for verdict in verdicts
        span = typed.spans[verdict.index]
        if isnothing(verdict.confidence)
            push!(failing, verdict.index)
            verdict.own || push!(found, verdict.index => BlindSpot("call fails on stand-in only", span))
        else
            push!(found, verdict.index => FailingCall(span, name_span(typed.site), callee_text(verdict.callee, typed.site.method.module), something(verdict.confidence)))
        end
    end
    return found, failing
end

"""Whether typed `statement` calls function or C code, assigned or not; stores are calls (`setfield!`, `setglobal!`)."""
effect_statement(@nospecialize(statement::Any))::Bool = (value = Widening.assigned(statement); value isa Expr && value.head in (:call, :foreigncall, :invoke))

"""Indexes of call statements typed `code` never reaches: inference wraps unreached statement in `Core.Const`."""
dead_calls(code::Core.CodeInfo)::Vector{Int} = [index for (index, statement) in enumerate(code.code) if statement isa Core.Const && effect_statement(statement.val)]

"""
Stand-in cuts of `typed` code of `method` on `signature` (`effects.md`, Stand-in cuts): dead call statements that
declared signature reaches, and `failing` calls (fail on stand-in only, `call_verdicts!`). Infers declared signature once per
method (`declared`), only for code with dead calls. Declared signature without code cannot clear dead call, so each
counts as cut; nor can generated code, whose statements differ per signature.
"""
function cuts!(declared::IdDict{Method, Union{Nothing, Core.CodeInfo}}, method::Method, signature::Type, code::Core.CodeInfo, failing::AbstractVector{<:Integer})::Vector{Int}
    dead = dead_calls(code)
    (isempty(dead) || signature == method.sig) && return failing
    reference = get!(() -> (result = Base.hasgenerator(method) ? nothing : infer(method, method.sig); isnothing(result) ? nothing : result[2]), declared, method)
    isnothing(reference) && return sort!([dead; failing])
    length(reference.code) == length(code.code) || error("declared and stand-in code of $method differ in length")
    return sort!([filter(index -> !(reference.code[index] isa Core.Const), dead); failing])
end

"""Whether inference `output` never returns and never throws: code loops or recurses without end."""
never_ends(output::Output)::Bool = output[3] === Union{} && CC.is_nothrow(output[6].result.ipo_effects)

"""
Confidence that `method` on unit `signature` never returns nor throws (`never_ends`), with compiler edges of inferences
it ran. `definite`: declared signature runs without end too; `possible`: only stand-in model signature does; `nothing`
when unit `output` ends, or only stand-in type keeps it running.
"""
function endless_verdict(method::Method, signature::Type, output::Output)::Tuple{Union{Nothing, Confidence.T}, Vector{Any}}
    never_ends(output) || return nothing, Any[]
    edges = Any[]
    for (reference, confidence) in ((method.sig, Confidence.definite), (StandIns.model_type(signature), Confidence.possible))
        inferred = reference == signature ? output : infer(method, reference)
        isnothing(inferred) && continue
        inferred === output || append!(edges, inferred[4])
        never_ends(inferred) && return confidence, edges
    end
    return nothing, edges
end

"""
Endless units of each package method: method site, its confidence, and for each unit its signature and package calls
that never return (call span => call signature).
"""
const EndlessUnits = IdDict{Method, Tuple{MethodSite, Confidence.T, Vector{Tuple{Type, Vector{Pair{Span, Type}}}}}}

"""
Units that call of `signature` reaches, as indices of `nodes` (method and signature): unit of same signature, else
every unit of callee. Callee without endless unit gives `0`: cause stays hidden, so no cycle around call reports.
"""
function call_targets(nodes::Vector{Tuple{Method, Type}}, by_method::IdDict{Method, Vector{Int}}, signature::Type)::Vector{Int}
    units = get(by_method, dispatched(signature), Int[])
    isempty(units) && return [0]
    exact = filter(index -> nodes[index][2] == signature, units)
    return isempty(exact) ? units : exact
end

"""Units that `edges` (unit to units its endless calls reach) lead to from `start`, through any number of calls."""
function reachable(edges::Vector{Vector{Int}}, start::Int)::BitSet
    found, pending = BitSet(), copy(edges[start])
    while !isempty(pending)
        node = pop!(pending)
        node in found && continue
        push!(found, node)
        node == 0 || append!(pending, edges[node])
    end
    return found
end

"""Source position of method `site`: file, then first byte."""
source_position(site::MethodSite)::Tuple{String, Int} = (site.span.file, site.span.first_byte)

"""
Endless cycles (`EndlessCycle`) of package `units`. Cycle of units reports when no endless call leaves it: caller of
endless unit only inherits it. Units, not methods, make cycle: `f(x::Real) = x isa Int ? g(x) : f(x)` with endless `g`
loops on its own for float stand-in. One fact per first method of cycle.
"""
function endless_cycles(units::EndlessUnits)::Vector{EndlessCycle}
    ordered = sort!(collect(keys(units)); by = method -> source_position(units[method][1]))
    nodes = Tuple{Method, Type}[(method, signature) for method in ordered for (signature, _) in units[method][3]]
    calls = Vector{Pair{Span, Type}}[unit_calls for method in ordered for (_, unit_calls) in units[method][3]]
    by_method = IdDict{Method, Vector{Int}}()
    for (index, (method, _)) in enumerate(nodes)
        push!(get!(Vector{Int}, by_method, method), index)
    end
    targets = [[call_targets(nodes, by_method, signature) for (_, signature) in unit_calls] for unit_calls in calls]
    edges = [reduce(vcat, unit_targets; init = Int[]) for unit_targets in targets]
    reach = [reachable(edges, index) for index in eachindex(nodes)]
    cycles, seen = IdDict{Method, Tuple{Vector{Label}, Bool}}(), BitSet()
    for index in eachindex(nodes)
        index in seen && continue
        cycle = push!(BitSet(node for node in reach[index] if node != 0 && index in reach[node]), index)
        union!(seen, cycle)
        # Every member reaches what first member reaches, so one check covers cycle.
        issubset(reach[index], cycle) || continue
        labels = [Label(span, "calls `$(dispatched(signature).name)`, which never returns") for node in cycle for ((span, signature), reached) in zip(calls[node], targets[node]) if any(in(cycle), reached)]
        definite = all(node -> units[first(nodes[node])][2] == Confidence.definite, cycle)
        # Nodes follow method order, so first node holds first method of cycle.
        found, certain = get(cycles, first(nodes[index]), (Label[], true))
        cycles[first(nodes[index])] = (append!(found, labels), certain && definite)
    end
    return map(filter(in(keys(cycles)), ordered)) do method
        labels, definite = cycles[method]
        # Stand-in units of one method repeat call span.
        closing = sort!(unique!(label -> label.span, labels); by = label -> (label.span.file, label.span.first_byte))
        return EndlessCycle(name_span(units[method][1]), Package.source_name(method), closing, definite ? Confidence.definite : Confidence.possible)
    end
end
