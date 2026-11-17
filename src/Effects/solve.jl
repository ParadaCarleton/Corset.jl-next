"""IR of instance before specialization, source statement index of each IR statement, and call outcome of each statement."""
struct Body
    ir::CC.IRCode
    lines::Vector{Int}
    outcomes::Vector{Union{Nothing, Outcome.Type}}
end

"""
Instance with constant arguments its callee uses as field name, by position (`effects.md`, Calls): `getproperty(x,
:a)` summary loads field `a`. Pre-inlining IR keeps such wrapper calls, so summary without constant loses field.
"""
const Variant = Tuple{Core.MethodInstance, Vector{Pair{Int, Any}}}

"""Code of variant for solve: specialized IR, statement lines and outcomes of its body, and variant each call reaches."""
struct Code
    ir::CC.IRCode
    lines::Vector{Int}
    outcomes::Vector{Union{Nothing, Outcome.Type}}
    callees::Vector{Union{Nothing, Variant}}
end

"""
State of one effects run: world of dispatch and native inference, crash journal, referent cache; per instance its body
or blind spot cause, and parameters it uses as field names; per variant its code and summary.
"""
struct Run
    world::UInt
    interpreter::CC.NativeInterpreter
    journal::Union{Nothing, Journal}
    referent::IdDict{Any, Bool}
    bodies::IdDict{Core.MethodInstance, Union{Body, String}}
    fields::IdDict{Core.MethodInstance, Set{Int}}
    codes::Dict{Variant, Code}
    summaries::Dict{Variant, Summary}
end

"""Run in current world with crash `journal`, before any code."""
function start_run(journal::Union{Nothing, Journal})::Run
    world = Base.get_world_counter()
    return Run(world, CC.NativeInterpreter(world), journal, IdDict(), IdDict(), IdDict(), Dict(), Dict())
end

"""Body of inference `frame` in `run`."""
function frame_body(run::Run, frame::CC.InferenceState)::Body
    ir, lines = frame_ir(frame, run.interpreter)
    return Body(ir, lines, [statement_outcome(ir, ir.stmts[index][:stmt], run.world) for index in 1:length(ir.stmts)])
end

"""Crash journal key of native inference of `instance`; prefix keeps it apart from method store keys."""
journal_key(instance::Core.MethodInstance)::String = "effects\n$(instance.specTypes)"

"""
Body of instance outside units: native inference, then passes. Blind spot cause instead when inference gives no code
or crashed earlier run; crash journal records each inference, so relaunch skips instance that aborts process.
"""
function library_body(run::Run, instance::Core.MethodInstance)::Union{Body, String}
    instance.def isa Method || return "inference gave no code"
    key, journal = journal_key(instance), run.journal
    isnothing(journal) || !(key in journal.crashed) || return "inference crashed process"
    isnothing(journal) || record!(journal, Record(key, method_label(instance.def), false, nothing))
    frame = CC.typeinf_frame(run.interpreter, instance, false)
    isnothing(journal) || record!(journal, Record(key, "", true, nothing))
    return isnothing(frame) ? "inference gave no code" : frame_body(run, frame)
end

"""Body of `instance`, inferred on first use."""
body!(run::Run, instance::Core.MethodInstance)::Union{Body, String} = get!(() -> library_body(run, instance), run.bodies, instance)

"""Builtins whose first two operands name slot: module and global name, or object and field."""
const NAMING_BUILTINS = (Core.getfield, Core.getglobal, keys(FIELD_WRITES)..., keys(GLOBAL_WRITES)...)

"""Parameter position of `operand` when it is argument of instance; `nothing` otherwise."""
function parameter_of(operand::Operand.Type)::Union{Nothing, Int}
    return @match operand begin
        Operand.Value(value) => value isa Core.Argument ? value.n : nothing
        Operand.Part(_, _) => nothing
    end
end

"""
Parameters `instance` uses as slot name: first two operands of naming builtin, or parameter it passes to such
parameter of callee. Cycle member in progress counts as none.
"""
function field_parameters!(run::Run, instance::Core.MethodInstance)::Set{Int}
    haskey(run.fields, instance) && return run.fields[instance]
    found = run.fields[instance] = Set{Int}()
    body = body!(run, instance)
    body isa Body || return found
    for outcome in body.outcomes
        isnothing(outcome) && continue
        @match something(outcome) begin
            Outcome.Builtin(builtin, operands) => any(candidate -> candidate === builtin, NAMING_BUILTINS) && union!(found, filter(!isnothing, parameter_of.(operands[1:min(2, end)])))
            Outcome.Static(callee, operands) => foreach(position -> union!(found, filter(!isnothing, [parameter_of(operands[position])])), filter(<=(length(operands)), collect(field_parameters!(run, callee))))
            _ => nothing
        end
    end
    return found
end

"""Variant that static call of `callee` with `operands` in `ir` reaches: constant slot names it passes."""
function callee_variant(run::Run, ir::CC.IRCode, callee::Core.MethodInstance, operands::Vector{Operand.Type})::Variant
    constants = Pair{Int, Any}[]
    method = callee.def::Method
    for position in sort!(collect(field_parameters!(run, callee)))
        position <= length(operands) && (position < method.nargs || !method.isva) || continue
        value = @match operands[position] begin
            Operand.Value(value) => constant(ir, value)
            Operand.Part(_, _) => nothing
        end
        !isnothing(value) && something(value) isa Union{Symbol, Int, Module} && push!(constants, position => something(value))
    end
    return (callee, constants)
end

"""Code of `variant` with body `body`: IR specialized to its constants, and variant each static call reaches."""
function variant_code(run::Run, variant::Variant, body::Body)::Code
    ir = specialize(body.ir, last(variant))
    callees = Union{Nothing, Variant}[nothing for _ in body.outcomes]
    for (index, outcome) in enumerate(body.outcomes)
        isnothing(outcome) && continue
        @match something(outcome) begin
            Outcome.Static(callee, operands) => (callees[index] = callee_variant(run, ir, callee, operands))
            _ => nothing
        end
    end
    return Code(ir, body.lines, body.outcomes, callees)
end

"""Variants `roots` reach through static calls, roots first; gives code to each variant with body."""
function reach!(run::Run, roots::Vector{Variant})::Vector{Variant}
    order, seen, pending = Variant[], Set{Variant}(), reverse(roots)
    while !isempty(pending)
        variant = pop!(pending)
        variant in seen && continue
        push!(seen, variant)
        push!(order, variant)
        body = body!(run, first(variant))
        body isa Body || continue
        code = run.codes[variant] = variant_code(run, variant, body)
        append!(pending, reverse(filter(!isnothing, code.callees)))
    end
    return order
end

"""Summary of `variant` with code, from current callee summaries of `run`: rounds over its IR until targets settle."""
function variant_summary(run::Run, variant::Variant)::Summary
    code = run.codes[variant]
    flow = start_flow(code.ir, code.outcomes, run.referent)
    while true
        flow.changed = false
        round!(flow, index -> run.summaries[something(code.callees[index])])
        flow.changed || break
    end
    return summarize(flow)
end

"""
Solve call cycle `members` (`effects.md`, Solve and cache): summaries start empty; member reruns only when summary of
callee in cycle that it reads changes. `readers` lists callers of each member inside cycle.
"""
function solve_cycle!(run::Run, members::Vector{Variant}, readers::Dict{Variant, Vector{Variant}})::Nothing
    for member in members
        body = run.bodies[first(member)]
        run.summaries[member] = body isa String ? open_summary((first(member).def::Method).nargs, body) : empty_summary()
    end
    queue = filter(member -> haskey(run.codes, member), members)
    queued = Set(queue)
    while !isempty(queue)
        member = popfirst!(queue)
        delete!(queued, member)
        summary = variant_summary(run, member)
        same(summary, run.summaries[member]) && continue
        run.summaries[member] = summary
        for reader in readers[member]
            reader in queued || (push!(queue, reader); push!(queued, reader))
        end
    end
    return nothing
end

"""Summaries of `roots` and every variant they reach: call graph cycles from Graphs.jl, solved callees first."""
function solve!(run::Run, roots::Vector{Variant})::Nothing
    order = reach!(run, roots)
    vertex = Dict(variant => position for (position, variant) in enumerate(order))
    graph = SimpleDiGraph(length(order))
    for (position, variant) in enumerate(order)
        haskey(run.codes, variant) || continue
        foreach(callee -> add_edge!(graph, position, vertex[callee]), filter(!isnothing, run.codes[variant].callees))
    end
    cycles = strongly_connected_components(graph)
    # Topological order puts callers first; solve runs callees first.
    for cycle in reverse(topological_sort_by_dfs(condensation(graph, cycles)))
        members = order[cycles[cycle]]
        inside = Set(members)
        readers = Dict(member => Variant[order[caller] for caller in inneighbors(graph, vertex[member]) if order[caller] in inside] for member in members)
        solve_cycle!(run, members, readers)
    end
    return nothing
end
