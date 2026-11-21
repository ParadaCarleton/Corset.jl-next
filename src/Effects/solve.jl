"""
IR of instance before specialization, source statement index of each IR statement, call outcome of each statement,
whether each statement builds thrown value only (`message_statements`), whether code uses value of each statement,
whether stand-ins cut path of its own code (`effects.md`, Stand-in cuts), and `shortcut`: compiler effects prove empty
summary (`proven_empty!`). Only unit keeps body with shortcut: its call facts need code.
"""
struct Body
    ir::CC.IRCode
    lines::Vector{Int}
    outcomes::Vector{Union{Nothing, Outcome.Type}}
    message::Vector{Bool}
    used::Vector{Bool}
    cut::Bool
    shortcut::Bool
end

"""
Code of variant for solve: specialized IR, statement lines, outcomes, message statements, used statements, cut and
shortcut of its body, and variants each call reaches.
"""
struct Code
    ir::CC.IRCode
    lines::Vector{Int}
    outcomes::Vector{Union{Nothing, Outcome.Type}}
    message::Vector{Bool}
    used::Vector{Bool}
    callees::Vector{Vector{Variant}}
    cut::Bool
    shortcut::Bool
end

"""Instance whose compiler effects prove empty summary (`effects.md`, Compiler effects): engine skips own analysis."""
struct Shortcut end

"""
Closure key state of one phase (`closure_key!`): component key per node of native edge graph (`nothing` when closure
has no key), throw helper callees each node's closure read, and instances store phase rejects (`library_entries`).
"""
struct Closure
    keys::IdDict{Any, Union{Nothing, String}}
    helpers::IdDict{Any, Vector{Any}}
    rejected::Base.IdSet{Core.MethodInstance}
end

"""Closure key state before any walk, with `rejected` instances."""
Closure(rejected::Base.IdSet{Core.MethodInstance})::Closure = Closure(IdDict{Any, Union{Nothing, String}}(), IdDict{Any, Vector{Any}}(), rejected)

"""
Summary cache state of one run (`library.jl`): library cache entries, instance key per instance (`instance_key!`),
text and named root modules per type (`type_text!`), owner texts and their digest per root module (`owners!`), own text per node
(`node_text!`), closure keys for lookup (`Closure`), answers of `names_package!`, native inference edges of each
instance run inferred (`inferred!`), instances of units method store served (`stored`), callees whose throw helper
verdict each instance read (`helper!`), instances whose cut read model-type inference (`stand_in_cut`), keys of
entries that hit, and text of alias methods outside Core (`alias_text`).
"""
struct Lookup
    library::Library
    keys::IdDict{Core.MethodInstance, String}
    types::IdDict{Any, Tuple{String, Vector{Module}}}
    owners::IdDict{Module, Union{Nothing, Vector{String}}}
    owned::IdDict{Module, Union{Nothing, String}}
    texts::IdDict{Any, Tuple{String, Vector{Any}}}
    closure::Closure
    named::IdDict{Any, Bool}
    edges::IdDict{Core.MethodInstance, Vector{Any}}
    stored::Base.IdSet{Core.MethodInstance}
    helpers::IdDict{Core.MethodInstance, Vector{Any}}
    modeled::Base.IdSet{Core.MethodInstance}
    hits::Set{String}
    aliases::String
end

"""
State of one effects run: world of dispatch and native inference, crash journal, package modules, referent cache; per
instance its body, shortcut or blind spot cause, caller that first reached it, and its variant parameters (`variant_parameters!`);
per method whether it claims effects and whether it catches; throw-helper verdict per callee (`throw_helper`); per
instance whether stand-ins cut its own code; instances whose reach compiler effects describe on model types too
(`reaches_untrusted!`); per variant its code and summary; summary cache state (`Lookup`).
"""
struct Run  # corset: allow wide-struct -- one memo per analysis; summary cache state nests in `Lookup`
    world::UInt
    interpreter::CC.NativeInterpreter
    journal::Union{Nothing, Journal}
    modules::Set{Module}
    referent::IdDict{Any, Bool}
    bodies::IdDict{Core.MethodInstance, Union{Body, Shortcut, String}}
    callers::IdDict{Core.MethodInstance, Core.MethodInstance}
    parameters::IdDict{Core.MethodInstance, Set{Int}}
    claims::IdDict{Method, Bool}
    catches::IdDict{Method, Bool}
    helpers::IdDict{Any, Tuple{Bool, Vector{Any}}}
    cuts::IdDict{Core.MethodInstance, Bool}
    trusted::Base.IdSet{Core.MethodInstance}
    codes::Dict{Variant, Code}
    summaries::Dict{Variant, Summary}
    cache::Lookup
end

"""Run in current world with crash `journal` for package `modules` and `library` cache, before any code."""
function start_run(journal::Union{Nothing, Journal}, modules::Vector{Module}, library::Library)::Run
    world = Base.get_world_counter()
    bodies, callers = IdDict{Core.MethodInstance, Union{Body, Shortcut, String}}(), IdDict{Core.MethodInstance, Core.MethodInstance}()
    parameters, claims, catches = IdDict{Core.MethodInstance, Set{Int}}(), IdDict{Method, Bool}(), IdDict{Method, Bool}()
    helpers, cuts, trusted = IdDict{Any, Tuple{Bool, Vector{Any}}}(), IdDict{Core.MethodInstance, Bool}(), Base.IdSet{Core.MethodInstance}()
    return Run(
        world, CC.NativeInterpreter(world), journal, Set(modules), IdDict{Any, Bool}(), bodies, callers, parameters, claims, catches, helpers, cuts, trusted, Dict{Variant, Code}(), Dict{Variant, Summary}(),
        Lookup(
            library, IdDict{Core.MethodInstance, String}(), IdDict{Any, Tuple{String, Vector{Module}}}(), IdDict{Module, Union{Nothing, Vector{String}}}(),
            IdDict{Module, Union{Nothing, String}}(), IdDict{Any, Tuple{String, Vector{Any}}}(), Closure(Base.IdSet{Core.MethodInstance}()), IdDict{Any, Bool}(), IdDict{Core.MethodInstance, Vector{Any}}(),
            Base.IdSet{Core.MethodInstance}(), IdDict{Core.MethodInstance, Vector{Any}}(), Base.IdSet{Core.MethodInstance}(), Set{String}(), alias_text(),
        ),
    )
end

"""Run of `start_run` without library cache: every instance gets native inference."""
start_run(journal::Union{Nothing, Journal}, modules::Vector{Module})::Run = start_run(journal, modules, Library())

"""
Whether `method` outside Base claims effects (`effects.md`, Compiler effects): `@assume_effects` on method or on block
in it. Generated method and method without source count: their code is unknown here.
"""
function claims!(run::Run, method::Method)::Bool
    haskey(run.claims, method) && return run.claims[method]
    claimed = if Base.moduleroot(method.module) in (Base, Core)
        false
    elseif method.purity != 0 || Base.hasgenerator(method) || method.source === nothing
        true
    else
        any(overrides, Base.uncompressed_ast(method).ssaflags)
    end
    run.claims[method] = claimed
    return claimed
end

"""Whether `method` can catch: `try` in its code. Generated method and method without source count: their code is unknown."""
function catches!(run::Run, method::Method)::Bool
    haskey(run.catches, method) && return run.catches[method]
    found = Base.hasgenerator(method) || method.source === nothing || any(statement -> statement isa Core.EnterNode, Base.uncompressed_ast(method).code)
    run.catches[method] = found
    return found
end

"""
Whether stand-ins cut own code of `instance` with cached compiler `effects` (`effects.md`, Stand-in cuts). Units come
cut or not from `run.cuts`. Other instance needs cut check (`stand_in_cut`) only when it holds stand-in, and its method
breaks no contract (type branches count, `keeps_contracts`) or its call can fail: it is not `nothrow`, or its method catches.
"""
function cut!(run::Run, instance::Core.MethodInstance, effects::CC.Effects)::Bool
    haskey(run.cuts, instance) && return run.cuts[instance]
    holds_stand_in(instance.specTypes) || return false
    method = instance.def::Method
    keeps_contracts(method) && CC.is_nothrow(effects) && !catches!(run, method) && return false
    stored = stored_cut(run, instance)
    isnothing(stored) || return (run.cuts[instance] = stored)
    # Instance without code counts as cut: its effects on model types are unknown.
    inferred = inferred!(run, instance)
    return inferred isa String ? (run.cuts[instance] = true) : last(inferred)
end

"""
Whether native inference `edges` (callee code instances) reach instance whose compiler effects can miss effects on model
types: method that `claims!` effects, instance that stand-ins cut (`cut!`), or callee without cached code. Search that
finds none marks every instance it visited trusted.
"""
function reaches_untrusted!(run::Run, edges::Union{Vector{Any}, Core.SimpleVector})::Bool
    visited, pending = Base.IdSet{Core.MethodInstance}(), Union{Vector{Any}, Core.SimpleVector}[edges]
    while !isempty(pending)
        for edge in pop!(pending)
            edge isa Union{Core.CodeInstance, Core.MethodInstance} || continue
            instance = edge isa Core.CodeInstance ? edge.def : edge
            instance isa Core.ABIOverride && (instance = instance.def)
            (instance in run.trusted || instance in visited) && continue
            push!(visited, instance)
            instance.def isa Method && claims!(run, instance.def) && return true
            code = edge isa Core.CodeInstance ? edge : CC.get(CC.code_cache(run.interpreter), instance, nothing)
            code isa Core.CodeInstance || return true
            cut!(run, instance, CC.decode_effects(code.ipo_purity_bits)) && return true
            push!(pending, code.edges)
        end
    end
    union!(run.trusted, visited)
    return false
end

"""Callee code instances of call with inference `info`."""
function call_edges(info::CC.CallInfo)::Vector{Any}
    edges = Any[]
    CC.add_edges!(edges, info)
    return edges
end

"""
Whether inference `frame` proves empty summary (`effects.md`, Compiler effects): instance writes nothing, touches no
caller memory or task state, returns value without reference, does not `claims!` effects, and its callees reach nothing
untrusted (`reaches_untrusted!`).
"""
function proven_empty!(run::Run, frame::CC.InferenceState)::Bool
    effects = frame.result.ipo_effects
    CC.is_effect_free(effects) && CC.is_inaccessiblememonly(effects) && CC.is_notaskstate(effects) || return false
    referent!(run.referent, CC.widenconst(frame.result.result)) && return false
    method = frame.linfo.def
    return !(method isa Method && claims!(run, method)) && !reaches_untrusted!(run, frame.edges)
end

"""Instances from `instance` back to root, each followed by caller that first reached it."""
function call_chain(run::Run, instance::Core.MethodInstance)::Vector{Core.MethodInstance}
    chain = [instance]
    while haskey(run.callers, chain[end])
        push!(chain, run.callers[chain[end]])
    end
    return chain
end

"""
Callee `callee` of call in first of `chain`, limited like native inference (`abstract_call_method`): method that
recurs on `chain` with other signature cannot grow past `limit_type_size`. Call that `joins` methods limits hard.
"""
function limit_callee(run::Run, chain::Vector{Core.MethodInstance}, callee::Core.MethodInstance, joins::Bool)::Core.MethodInstance
    method, signature, caller, topmost = callee.def::Method, callee.specTypes, first(chain), 0
    for (position, link) in enumerate(chain)
        link.def === method || continue
        # Same signature: call cycle, solve settles it.
        link.specTypes == signature && return callee
        topmost == 0 || continue
        # Soft limit needs repeated edge: link reached from method of caller.
        repeated = position < length(chain) && chain[position + 1].def === caller.def
        (joins || repeated) && (topmost = position)
    end
    topmost == 0 && return callee
    self = method === caller.def
    width = max(length((Base.unwrap_unionall(method.sig)::DataType).parameters) + 1, self ? length((Base.unwrap_unionall(caller.specTypes)::DataType).parameters) : 0)
    comparison = self ? caller.specTypes : joins ? method.sig : chain[topmost].specTypes
    limited = CC.limit_type_size(signature, comparison, joins ? comparison : caller.specTypes, CC.InferenceParams(run.interpreter).tuple_complexity_limit_depth, width)
    limited === signature && return callee
    environment = (ccall(:jl_type_intersection_with_env, Any, (Any, Any), limited, method.sig)::Core.SimpleVector)[2]
    return CC.specialize_method(method, limited, environment::Core.SimpleVector)
end

"""Callees `instances` of call in first of `chain`, limited (`limit_callee`); records first caller of each new callee."""
function limit_callees!(run::Run, chain::Vector{Core.MethodInstance}, instances::Vector{Core.MethodInstance})::Vector{Core.MethodInstance}
    limited = Core.MethodInstance[limit_callee(run, chain, instance, length(instances) > 1) for instance in instances]
    for callee in limited
        # Unit has no first caller: its body starts chain.
        callee === first(chain) || haskey(run.bodies, callee) || callee in run.cache.stored || haskey(run.callers, callee) || (run.callers[callee] = first(chain))
    end
    return limited
end

"""Outcome `outcome` of statement in first of `chain`, with callees of dispatch limited (`limit_callees!`)."""
function limited_outcome(run::Run, chain::Vector{Core.MethodInstance}, outcome::Union{Nothing, Outcome.Type})::Union{Nothing, Outcome.Type}
    isnothing(outcome) && return nothing
    return @match something(outcome) begin
        Outcome.Dispatch(instances, operands) => Outcome.Dispatch(limit_callees!(run, chain, instances), operands)
        _ => outcome
    end
end

"""
Most methods call in `instance` joins: `JOIN_LIMIT` in package module, else 1. Joins in library code raised `possible`
share on corpus, and JSON `effects` time went past 30 min.
"""
join_limit(run::Run, instance::Core.MethodInstance)::Int = (instance.def::Method).module in run.modules ? JOIN_LIMIT : 1

"""Whether statement `flag` carries block `@assume_effects` override."""
overrides(flag::UInt32)::Bool = CC.decode_statement_effects_override(flag) != CC.EffectsOverride()

"""
Body of inference `frame` in `run`, whose own code stand-ins `cut`, with `shortcut` (`Body`); callees that grow along
call chain are limited. Compaction keeps calls that reach untrusted instance (`reaches_untrusted!`), and statements
under block claim of instance that `claims!` effects. Unit keeps every call: call facts need discarded calls too.
"""
function frame_body(run::Run, frame::CC.InferenceState, cut::Bool, unit::Bool, shortcut::Bool)::Body
    method = frame.linfo.def
    own = method isa Method && claims!(run, method)
    kept = [
        (unit && call_statement(frame.src.code[index])) || (own && overrides(frame.src.ssaflags[index])) || reaches_untrusted!(run, call_edges(info))
            for (index, info) in enumerate(frame.stmt_info)
    ]
    ir, lines, before = frame_ir(frame, run.interpreter, kept)
    chain, limit = call_chain(run, frame.linfo), join_limit(run, frame.linfo)
    outcomes = [limited_outcome(run, chain, statement_outcome(ir, ir.stmts[index][:stmt], run.world, limit)) for index in 1:length(ir.stmts)]
    users = statement_users(ir)
    # Statement compiler inserted has no source statement: its uses after compaction count.
    used = [iszero(line) ? !isempty(users[index]) : before[line] for (index, line) in enumerate(lines)]
    return Body(ir, lines, outcomes, message_statements(users, throw_sinks(run, frame.linfo, ir)), used, cut, shortcut)
end

"""
Whether each statement of `ir` of `instance` throws: call of `throw` or throw helper (`helper!`). Other call that never
returns fails on stand-in: no sink, since stand-ins cut it.
"""
function throw_sinks(run::Run, instance::Core.MethodInstance, ir::CC.IRCode)::Vector{Bool}
    sinks = fill(false, length(ir.stmts))
    for index in 1:length(ir.stmts)
        statement = ir.stmts[index][:stmt]
        statement isa Expr || continue
        (statement.head === :call && ir.stmts[index][:type] === Union{}) || continue
        callee = called(ir, statement, ir.sptypes)
        sinks[index] = !isnothing(callee) && helper!(run, instance, callee)
    end
    return sinks
end

"""
Whether stand-ins cut path of library instance `frame` (`effects.md`, Stand-in cuts): reached call never returns, or
call statement is dead, though model types reach it. Methods that keep contracts count failing calls only
(`keeps_contracts`); throw helpers fail on every signature. Method of stand-in only, generated method, or instance on
model types without code, cannot clear call, so it counts as cut. Instance whose check infers model types joins
`modeled`: that inference reads methods outside its native edges.
"""
function stand_in_cut(run::Run, frame::CC.InferenceState)::Bool
    instance, code = frame.linfo, frame.src
    holds_stand_in(instance.specTypes) || return false
    method = instance.def::Method
    # Loop keeps `callee` typed `Any`: filter closure would compile once per callee type.
    failing = Int[]
    for (index, _, callee) in never_returning(code, CC.sptypes_from_meth_instance(instance))
        helper!(run, instance, callee) || push!(failing, index)
    end
    dead = keeps_contracts(method) ? Int[] : dead_calls(code)
    isempty(failing) && isempty(dead) && return false
    # Generated code differs per signature, so statement index of stand-in code names no statement of model code.
    Base.hasgenerator(method) && return true
    modeled = Inference.instance(method, model_type(instance.specTypes))
    isnothing(modeled) || push!(run.cache.modeled, instance)
    reference = isnothing(modeled) ? nothing : CC.typeinf_frame(run.interpreter, modeled, false)
    isnothing(reference) && return true
    return any(index -> reference.src.ssavaluetypes[index] !== Union{}, failing) || any(index -> !(reference.src.code[index] isa Core.Const), dead)
end

"""
Whether `method` keeps documented contracts, so its type branches keep same effects (`findings.md`, Confidence and
blind spots): Base, Core, and stand-in methods that model them.
"""
keeps_contracts(method::Method)::Bool = Base.moduleroot(method.module) in (Base, Core) || method.module === StandIns

"""
Crash journal key of native inference of `instance`; prefix keeps it apart from method store keys. Non-compact `show`
skips type alias search, which takes seconds on deep types.
"""
journal_key(instance::Core.MethodInstance)::String = "effects\n" * sprint(show, instance.specTypes; context = :compact => false)

"""
Body of inference `frame` whose own code stand-ins `cut`, or shortcut when its compiler effects prove empty summary
(`proven_empty!`). Compiler effects hold for stand-ins only, so cut instance gets no shortcut.
"""
instance_body(run::Run, frame::CC.InferenceState, cut::Bool)::Union{Body, Shortcut} = !cut && proven_empty!(run, frame) ? Shortcut() : frame_body(run, frame, cut, false, false)

"""
Body of unit with inference `frame` whose own code stand-ins `cut`: every call stays, and shortcut (`instance_body`)
keeps code for call facts.
"""
unit_body(run::Run, frame::CC.InferenceState, cut::Bool)::Body = frame_body(run, frame, cut, true, !cut && proven_empty!(run, frame))

"""
Native inference frame of instance outside units, and whether stand-ins cut it (`stand_in_cut`, kept in `run.cuts`).
Blind spot cause instead when inference gives no code or crashed earlier run; crash journal records each inference, so
relaunch skips instance that aborts process.
"""
function inferred!(run::Run, instance::Core.MethodInstance)::Union{Tuple{CC.InferenceState, Bool}, String}
    journal = run.journal
    key = isnothing(journal) ? "" : journal_key(instance)
    isnothing(journal) || !(key in journal.crashed) || return "inference crashed process"
    isnothing(journal) || record!(journal, Record(key, method_label(instance.def::Method), false, nothing))
    frame = CC.typeinf_frame(run.interpreter, instance, false)
    isnothing(frame) || (run.cache.edges[instance] = frame.edges)
    # Model-type inference of cut check runs inside journal record too; library cache can spare it.
    cut = !isnothing(frame) && get!(() -> stored_or_cut(run, instance, frame), run.cuts, instance)
    isnothing(journal) || record!(journal, Record(key, "", true, nothing))
    return isnothing(frame) ? "inference gave no code" : (frame, cut)
end

"""Body of instance outside units: native inference (`inferred!`), then shortcut or passes; else blind spot cause."""
library_body(run::Run, instance::Core.MethodInstance)::Union{Body, Shortcut, String} = (inferred = inferred!(run, instance); inferred isa String ? inferred : instance_body(run, inferred...))

"""
Body of `instance`, inferred on first use. Instance of stored unit (`Run`) takes unit body (`unit_body`) of native
inference, as run that infers unit gives it.
"""
body!(run::Run, instance::Core.MethodInstance)::Union{Body, Shortcut, String} = get!(() -> instance in run.cache.stored ? stored_body(run, instance) : library_body(run, instance), run.bodies, instance)

"""Unit body of stored unit `instance` from native inference (`inferred!`); else blind spot cause."""
stored_body(run::Run, instance::Core.MethodInstance)::Union{Body, String} = (inferred = inferred!(run, instance); inferred isa String ? inferred : unit_body(run, inferred...))

"""Builtins whose first two operands name slot: module and global name, or object and field."""
const NAMING_BUILTINS = (Core.getfield, Core.getglobal, keys(FIELD_WRITES)..., keys(GLOBAL_WRITES)...)

"""Whether `builtin` names slot with its first two operands (`NAMING_BUILTINS`)."""
naming(@nospecialize(builtin::Any))::Bool = any(candidate -> candidate === builtin, NAMING_BUILTINS)

"""Add parameter position of each of `operands` at `positions` that is argument of instance."""
function add_parameters!(found::Set{Int}, operands::Vector{Operand.Type}, positions::Any)::Nothing
    for position in positions
        position <= length(operands) || continue
        parameter = parameter_of(operands[position])
        isnothing(parameter) || push!(found, parameter)
    end
    return nothing
end

"""Parameter position of `operand` when it is argument of instance; `nothing` otherwise."""
function parameter_of(operand::Operand.Type)::Union{Nothing, Int}
    return @match operand begin
        Operand.Value(value) => value isa Core.Argument ? value.n : nothing
        _ => nothing
    end
end

"""Variant parameters of instance in progress, its calls as operands and callee, and position of next call."""
mutable struct ParametersFrame
    const found::Set{Int}
    const calls::Vector{Pair{Vector{Operand.Type}, Core.MethodInstance}}
    next::Int
end

"""Add call with `operands` to each of `callees` to `calls`."""
function append_calls!(calls::Vector{Pair{Vector{Operand.Type}, Core.MethodInstance}}, operands::Vector{Operand.Type}, callees::Vector{Core.MethodInstance})::Nothing
    foreach(callee -> push!(calls, operands => callee), callees)
    return nothing
end

"""
Frame of `instance`, recorded in progress: branch conditions and operands of naming builtins added now, calls wait for
callee. Library cache entry gives parameters at once, without code.
"""
function parameters_frame!(run::Run, instance::Core.MethodInstance)::ParametersFrame
    stored = stored_parameters(run, instance)
    found = run.parameters[instance] = isnothing(stored) ? Set{Int}() : copy(stored)
    frame = ParametersFrame(found, Pair{Vector{Operand.Type}, Core.MethodInstance}[], 1)
    isnothing(stored) || return frame
    body = body!(run, instance)
    body isa Body || return frame
    for index in 1:length(body.ir.stmts)
        statement = body.ir.stmts[index][:stmt]
        statement isa Core.GotoIfNot && statement.cond isa Core.Argument && push!(found, statement.cond.n)
    end
    for outcome in body.outcomes
        isnothing(outcome) && continue
        @match something(outcome) begin
            Outcome.Builtin(builtin, operands) => naming(builtin) && add_parameters!(frame.found, operands, 1:min(2, length(operands)))
            # Closure inside `@match` arm boxes its captures: helper keeps loop out of arm.
            Outcome.Dispatch(callees, operands) => append_calls!(frame.calls, operands, callees)
            _ => nothing
        end
    end
    return frame
end

"""
Variant parameters of `instance` (`effects.md`, Calls): branch condition, first two operands of naming builtin (slot
name), or parameter it passes to variant parameter of callee. Cycle member in progress counts as found so far. Explicit
stack: deep call chains need no deep recursion.
"""
function variant_parameters!(run::Run, instance::Core.MethodInstance)::Set{Int}
    haskey(run.parameters, instance) && return run.parameters[instance]
    stack = [parameters_frame!(run, instance)]
    while !isempty(stack)
        frame = stack[end]
        frame.next > length(frame.calls) && (pop!(stack); continue)
        operands, callee = frame.calls[frame.next]
        haskey(run.parameters, callee) || (push!(stack, parameters_frame!(run, callee)); continue)
        add_parameters!(frame.found, operands, run.parameters[callee])
        frame.next += 1
    end
    return run.parameters[instance]
end

"""Variant that static call of `callee` with `operands` in `ir` reaches: constants it passes to variant parameters."""
function callee_variant(run::Run, ir::CC.IRCode, callee::Core.MethodInstance, operands::Vector{Operand.Type})::Variant
    constants = Pair{Int, Any}[]
    method = callee.def::Method
    for position in sort!(collect(variant_parameters!(run, callee)))
        position <= length(operands) && (position < method.nargs || !method.isva) || continue
        value = operand_constant(ir, operands[position])
        !isnothing(value) && something(value) isa VariantConstant && push!(constants, position => something(value))
    end
    return (callee, constants)
end

"""Variants that call with `operands` in `ir` reaches through each of `instances`."""
callee_variants(run::Run, ir::CC.IRCode, instances::Vector{Core.MethodInstance}, operands::Vector{Operand.Type})::Vector{Variant} = [callee_variant(run, ir, instance, operands) for instance in instances]

"""
Code of `variant` with body `body`: IR specialized to its constants, and variants each call reaches. Comprehension
lives in `kept_outcomes`: `@match` here would box its captures.
"""
function variant_code(run::Run, variant::Variant, body::Body)::Code
    ir = specialize(body.ir, last(variant))
    outcomes = kept_outcomes(ir, body)
    callees = [Variant[] for _ in outcomes]
    for (index, outcome) in enumerate(outcomes)
        isnothing(outcome) && continue
        @match something(outcome) begin
            Outcome.Dispatch(instances, operands) => (callees[index] = callee_variants(run, ir, instances, operands))
            _ => nothing
        end
    end
    return Code(ir, body.lines, outcomes, body.message, body.used, callees, body.cut, body.shortcut)
end

"""Outcomes of `body` that specialized `ir` keeps: statement that specialization drops (`drop_unreached`) has none."""
function kept_outcomes(ir::CC.IRCode, body::Body)::Vector{Union{Nothing, Outcome.Type}}
    ir.stmts === body.ir.stmts && return body.outcomes
    return Union{Nothing, Outcome.Type}[isnothing(ir.stmts[index][:stmt]) ? nothing : outcome for (index, outcome) in enumerate(body.outcomes)]
end

"""
Variants `roots` reach through calls, roots first; gives code to each variant with body. Variant that library cache
holds takes stored summary (hit): it needs no body, and walk stops there.
"""
function reach!(run::Run, roots::Vector{Variant})::Vector{Variant}
    order, seen, pending = Variant[], Set{Variant}(), reverse(roots)
    while !isempty(pending)
        variant = pop!(pending)
        variant in seen && continue
        push!(seen, variant)
        push!(order, variant)
        stored = stored_summary(run, variant)
        isnothing(stored) || (run.summaries[variant] = stored; continue)
        body = body!(run, first(variant))
        body isa Body || continue
        code = run.codes[variant] = variant_code(run, variant, body)
        foreach(callees -> append!(pending, Iterators.reverse(callees)), Iterators.reverse(code.callees))
    end
    return order
end

"""
Flow of `variant` with code at fixpoint, from current callee summaries of `run`: rounds over its IR until targets
settle, then one settled round for callee accesses (`Flow`). Also gives its callees, with variants whose summaries
rounds read. `flush` resolves callback records here; `record` keeps write kinds of each call (`Flow`).
"""
function variant_flow(run::Run, variant::Variant, flush::Bool, record::Bool)::Tuple{Flow, Callees}
    code = run.codes[variant]
    flow = start_flow(code.ir, code.outcomes, code.message, run.referent, flush, code.cut, static_sources(first(variant).def::Method), record)
    callees = Callees(code.callees, run.summaries, Set{Variant}())
    while true
        flow.changed = false
        round!(flow, callees)
        # Settled round repeats state of round before it; growth there is engine bug.
        if flow.settled
            flow.changed && error("settled round of $(first(variant)) changed targets")
            break
        end
        flow.changed || (flow.settled = true)
    end
    return flow, callees
end

"""
Summary of `variant` with code, from current callee summaries of `run` (`variant_flow`), and variants whose summaries
rounds read. `flush` resolves callback records here.
"""
function variant_summary(run::Run, variant::Variant, flush::Bool)::Tuple{Summary, Set{Variant}}
    flow, callees = variant_flow(run, variant, flush, false)
    return summarize(flow, first(variant).def::Method, callees), callees.read
end

"""
Summary of root `variant` for verdicts after solve: no caller resolves its callback records, so root with records
reruns with each record resolved at call statement where it starts.
"""
function root_summary(run::Run, variant::Variant)::Summary
    summary = run.summaries[variant]
    isempty(summary.callbacks) && return summary
    return first(variant_summary(run, variant, true))
end

"""
Call statement facts of root `variant` with code (`effects.md`, Facts), by IR statement: rerun resolves callback records
at call, as root has no caller, and records write kinds of each call.
"""
function root_calls(run::Run, variant::Variant)::Vector{Pair{Int, CallRecord}}
    flow = first(variant_flow(run, variant, true, true))
    code = run.codes[variant]
    return [index => call_record(flow, index, code.used[index]) for index in 1:length(code.ir.stmts) if !isnothing(code.outcomes[index])]
end

"""Reruns of call cycle member before each new summary widens by its previous one (`widen`)."""
const WIDEN_AFTER = 8

"""
Solve call cycle `members` (`effects.md`, Solve and cache): summaries start empty; member reruns only when summary of
member it read changes, and widens after `WIDEN_AFTER` reruns. Member reads callee summaries and variants of callback
records it resolves, so readers come from each solve.
"""
function solve_cycle!(run::Run, members::Vector{Variant})::Nothing
    for member in members
        body = run.bodies[first(member)]
        run.summaries[member] = body isa String ? open_summary(Int((first(member).def::Method).nargs), body) : empty_summary()
    end
    readers = Dict(member => Variant[] for member in members)
    # Shortcut unit keeps code for call facts; its summary stays empty.
    queue = filter(member -> haskey(run.codes, member) && !run.codes[member].shortcut, members)
    queued, reruns = Set(queue), Dict{Variant, Int}()
    while !isempty(queue)
        member = popfirst!(queue)
        delete!(queued, member)
        summary, read = variant_summary(run, member, false)
        for callee in read
            haskey(readers, callee) && !(member in readers[callee]) && push!(readers[callee], member)
        end
        reruns[member] = get(reruns, member, 0) + 1
        reruns[member] > WIDEN_AFTER && (summary = widen(run.summaries[member], summary))
        same(summary, run.summaries[member]) && continue
        run.summaries[member] = summary
        for reader in readers[member]
            reader in queued || (push!(queue, reader); push!(queued, reader))
        end
    end
    return nothing
end

"""
Strongly connected components of graph with `successors` of each vertex, each component after every component it
reaches: callees before callers. Tarjan's algorithm with explicit stack, so deep call chains need no deep recursion.
"""
function components(successors::Vector{Vector{Int}})::Vector{Vector{Int}}
    index, low, open = zeros(Int, length(successors)), zeros(Int, length(successors)), falses(length(successors))
    stack, found, count = Int[], Vector{Int}[], 0
    for root in eachindex(successors)
        index[root] == 0 || continue
        # Each entry: vertex and how many of its successors walk has visited.
        work = [(root, 0)]
        while !isempty(work)
            vertex, visited = work[end]
            if visited == 0
                count += 1
                index[vertex] = low[vertex] = count
                push!(stack, vertex)
                open[vertex] = true
            end
            if visited < length(successors[vertex])
                work[end] = (vertex, visited + 1)
                child = successors[vertex][visited + 1]
                if index[child] == 0
                    push!(work, (child, 0))
                elseif open[child]
                    low[vertex] = min(low[vertex], index[child])
                end
                continue
            end
            pop!(work)
            isempty(work) || (low[first(work[end])] = min(low[first(work[end])], low[vertex]))
            low[vertex] == index[vertex] || continue
            component = Int[]
            while isempty(component) || last(component) != vertex
                member = pop!(stack)
                open[member] = false
                push!(component, member)
            end
            push!(found, component)
        end
    end
    return found
end

"""Callee positions in `order` of each variant of `order` with code: call graph of solve."""
function call_graph(run::Run, order::Vector{Variant})::Vector{Vector{Int}}
    vertex = Dict(variant => position for (position, variant) in enumerate(order))
    successors = [Int[] for _ in order]
    for (position, variant) in enumerate(order)
        haskey(run.codes, variant) || continue
        for callees in run.codes[variant].callees, callee in callees
            push!(successors[position], vertex[callee])
        end
        unique!(successors[position])
    end
    return successors
end

"""
Summaries of `roots` and every variant they reach: call graph components solved callees first. Library cache hit has
no code, so it forms component alone and keeps its stored summary.
"""
function solve!(run::Run, roots::Vector{Variant})::Nothing
    order = reach!(run, roots)
    for component in components(call_graph(run, order))
        members = order[component]
        # Only hit has summary before its component solves.
        all(member -> haskey(run.summaries, member), members) && continue
        solve_cycle!(run, members)
    end
    return nothing
end
