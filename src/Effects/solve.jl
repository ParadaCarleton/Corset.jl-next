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

"""Code of variant for solve: specialized IR, statement lines and outcomes of its body, and variants each call reaches."""
struct Code
    ir::CC.IRCode
    lines::Vector{Int}
    outcomes::Vector{Union{Nothing, Outcome.Type}}
    callees::Vector{Vector{Variant}}
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
    bodies, fields = IdDict{Core.MethodInstance, Union{Body, String}}(), IdDict{Core.MethodInstance, Set{Int}}()
    return Run(world, CC.NativeInterpreter(world), journal, IdDict{Any, Bool}(), bodies, fields, Dict{Variant, Code}(), Dict{Variant, Summary}())
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
    key, journal = journal_key(instance), run.journal
    isnothing(journal) || !(key in journal.crashed) || return "inference crashed process"
    isnothing(journal) || record!(journal, Record(key, method_label(instance.def::Method), false, nothing))
    frame = CC.typeinf_frame(run.interpreter, instance, false)
    isnothing(journal) || record!(journal, Record(key, "", true, nothing))
    return isnothing(frame) ? "inference gave no code" : frame_body(run, frame)
end

"""Body of `instance`, inferred on first use."""
body!(run::Run, instance::Core.MethodInstance)::Union{Body, String} = get!(() -> library_body(run, instance), run.bodies, instance)

"""Builtins whose first two operands name slot: module and global name, or object and field."""
const NAMING_BUILTINS = (Core.getfield, Core.getglobal, keys(FIELD_WRITES)..., keys(GLOBAL_WRITES)...)

"""Whether `builtin` names slot with its first two operands (`NAMING_BUILTINS`)."""
naming(builtin::Any)::Bool = any(candidate -> candidate === builtin, NAMING_BUILTINS)

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
            Outcome.Builtin(builtin, operands) => naming(builtin) && add_parameters!(found, operands, 1:min(2, length(operands)))
            Outcome.Dispatch(callees, operands) => foreach(callee -> add_parameters!(found, operands, field_parameters!(run, callee)), callees)
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

"""Code of `variant` with body `body`: IR specialized to its constants, and variants each call reaches."""
function variant_code(run::Run, variant::Variant, body::Body)::Code
    ir = specialize(body.ir, last(variant))
    callees = [Variant[] for _ in body.outcomes]
    for (index, outcome) in enumerate(body.outcomes)
        isnothing(outcome) && continue
        @match something(outcome) begin
            Outcome.Dispatch(instances, operands) => (callees[index] = [callee_variant(run, ir, instance, operands) for instance in instances])
            _ => nothing
        end
    end
    return Code(ir, body.lines, body.outcomes, callees)
end

"""Variants `roots` reach through calls, roots first; gives code to each variant with body."""
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
        foreach(callees -> append!(pending, Iterators.reverse(callees)), Iterators.reverse(code.callees))
    end
    return order
end

"""Summary of `variant` with code, from current callee summaries of `run`: rounds over its IR until targets settle."""
function variant_summary(run::Run, variant::Variant)::Summary
    code = run.codes[variant]
    flow = start_flow(code.ir, code.outcomes, run.referent)
    while true
        flow.changed = false
        round!(flow, (index, member) -> run.summaries[code.callees[index][member]])
        flow.changed || break
    end
    return summarize(flow)
end

"""Reruns of call cycle member before each new summary widens by its previous one (`widen`)."""
const WIDEN_AFTER = 8

"""
Solve call cycle `members` (`effects.md`, Solve and cache): summaries start empty; member reruns only when summary of
callee in cycle that it reads changes, and widens after `WIDEN_AFTER` reruns. `readers` lists callers inside cycle.
"""
function solve_cycle!(run::Run, members::Vector{Variant}, readers::Dict{Variant, Vector{Variant}})::Nothing
    for member in members
        body = run.bodies[first(member)]
        run.summaries[member] = body isa String ? open_summary(Int((first(member).def::Method).nargs), body) : empty_summary()
    end
    queue = filter(member -> haskey(run.codes, member), members)
    queued, reruns = Set(queue), Dict{Variant, Int}()
    while !isempty(queue)
        member = popfirst!(queue)
        delete!(queued, member)
        summary = variant_summary(run, member)
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

"""Summaries of `roots` and every variant they reach: call graph components solved callees first."""
function solve!(run::Run, roots::Vector{Variant})::Nothing
    order = reach!(run, roots)
    vertex = Dict(variant => position for (position, variant) in enumerate(order))
    successors = [Int[] for _ in order]
    for (position, variant) in enumerate(order)
        haskey(run.codes, variant) || continue
        for callees in run.codes[variant].callees, callee in callees
            push!(successors[position], vertex[callee])
        end
        unique!(successors[position])
    end
    for component in components(successors)
        inside = Set(component)
        readers = Dict(order[member] => Variant[] for member in component)
        for caller in component, callee in successors[caller]
            callee in inside && push!(readers[order[callee]], order[caller])
        end
        solve_cycle!(run, order[component], readers)
    end
    return nothing
end
