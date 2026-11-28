# Unit records and method facts of name tier (`effects.md`, Units and IR, Facts).

"""Blind spot cause of unit that always throws on stand-ins: it shows no behavior of declared signature."""
const ALWAYS_THROWS = "always throws on stand-ins"

"""Blind spot cause of method whose facts hold no write on path stand-ins cut (`effects.md`, Stand-in cuts)."""
const CUT = "stand-in cuts path"

"""Blind spot cause of discarded call without effect that mapping cannot place: `unused-call` cannot name it."""
const UNSPANNED_CALL = "call without effect lacks exact span"

"""Most methods call statement callee joins: compiler `max_methods`. More gives open callee."""
const DISPATCH_LIMIT = 3

"""
Effects record of unit `typed` (`effects.md`, Units and IR): events of each IR statement, result aliases and call
facts. `effect_free`: compiler proves unit writes nothing caller sees; stand-in signature, claim in method, or claim of
direct callee gives no proof. Crash `journal` records offset inference of index proof (`unit_indices`), whose compiler
edges come second: `nothing` when it failed. Unit that always throws on stand-ins gives no verdict, only blind spot.
"""
function unit_effects(typed::TypedCode, modules::AbstractSet{Module}, interpreter::CC.NativeInterpreter, world::UInt, journal::Union{Nothing, Inference.Journal})::Tuple{UnitEffects, Union{Nothing, Vector{Any}}}
    cut = isempty(typed.cuts) ? nothing : typed.spans[first(typed.cuts)]
    typed.result === Union{} && return UnitEffects(false, Access[], Access[], Place.Type[], UnguardedHold[], UnitCalls(), LoopWrite[], SelfAlias[], StatefulReuse[], IndexFacts(), ArrayLife[], [BlindSpot(ALWAYS_THROWS, typed.site.span)], false, false, cut), Any[]
    walk, lines, used, claimed = unit_walk(typed, modules, interpreter, world)
    ir = walk.ir
    walk_values!(walk, 2 * length(ir.stmts) + 10)
    users = statement_users(ir)
    writes, reads, aliases, calls, callee_claimed, new_result = Access[], Access[], Set{Place.Type}(), UnitCalls(), false, false
    spans = Span[line in eachindex(typed.spans) ? typed.spans[line] : typed.site.span for line in lines]
    for index in 1:length(ir.stmts)
        line, span = lines[index], spans[index]
        events, invoked = statement_events(walk, index)
        foreach(event -> push!(event.write ? writes : reads, Access(event.place, event.below, event.kind, event.confidence, false, span)), events)
        statement = ir.stmts[index][:stmt]
        if statement isa Core.ReturnNode && isdefined(statement, :val)
            returned = operand_value(walk, statement.val)
            union!(aliases, held(returned))
            new_result |= returns_new(walk, statement.val, returned)
        end
        statement isa Expr || continue
        statement.head in (:call, :foreigncall) || continue
        # Compiler trusts claim of direct callee too (`@assume_effects`); keyword call hides its callee, so it counts.
        fact = call_fact(walk, index, events, invoked, span, iszero(line) ? !isempty(users[index]) : used[line])
        callee_claimed |= statement.head === :call && callee_claims(walk, statement, fact.callee)
        push!(calls, (line, span) => fact)
    end
    effect_free = CC.is_effect_free(typed.frame.ipo_effects) && !claimed && !holds_stand_in(typed.signature) && !callee_claimed
    loops, loop_spots = loop_writes(walk, spans)
    reuses, reuse_spots = stateful_reuses(walk, typed.site.method, spans)
    indices, index_spots, edges = unit_indices(typed, walk, interpreter, journal)
    unspanned = [BlindSpot(UNSPANNED_CALL, span) for ((line, span), fact) in calls if line in typed.unmapped && no_effect(fact)]
    unguarded = unguarded_holds(walk, spans)
    return UnitEffects(true, writes, reads, text_order(collect(aliases), repr), unguarded, calls, loops, self_aliases(walk, spans), reuses, indices, unit_arrays(walk, lines, spans), [loop_spots; reuse_spots; index_spots; unspanned], effect_free, new_result, cut), edges
end

"""
Whether returned `operand` of `walk`, of `value`, gives caller new value (F86): not `nothing`, and neither argument
nor value that holds argument or lies below it.
"""
function returns_new(walk::Walk, @nospecialize(operand::Any), value::Value)::Bool
    operand_type(walk, operand) <: Nothing && return false
    root = underlying(walk, operand)
    root isa Core.Argument && root.n >= 2 && return false
    return !any(place -> argument_root(place_root(place)), held(value))
end

"""Whether `root` is argument of method; first parameter is called function."""
argument_root(root::Root.Type)::Bool = @match root begin
    Root.Parameter(position) => position >= 2
    _ => false
end

"""
Walk of unit `typed` before `walk_values!`, source line of each IR statement, use of each source line, and whether method
claims `:effect_free` (`frame_walk`).
"""
unit_walk(typed::TypedCode, modules::AbstractSet{Module}, interpreter::CC.NativeInterpreter, world::UInt)::Tuple{Walk, Vector{Int}, Vector{Bool}, Bool} = frame_walk(typed.frame, typed.site.method, modules, interpreter, world)

"""
Walk of inference `frame` of `method` before `walk_values!`, source line of each IR statement, use of each source line,
and whether method claims `:effect_free`.
"""
function frame_walk(frame::CC.InferenceState, method::Method, modules::AbstractSet{Module}, interpreter::CC.NativeInterpreter, world::UInt)::Tuple{Walk, Vector{Int}, Vector{Bool}, Bool}
    ir, lines, used = frame_ir(frame, interpreter, Bool[call_statement(statement) for statement in frame.src.code])
    # Source flags keep compiler `effect_free`, which `frame_ir` clears on kept calls. Claim in method voids proof.
    # Inferred flags reuse claim bits, so claim reads code before inference.
    flags, claimed = frame.src.ssaflags, claims_effect_free(method, CC.retrieve_code_info(frame.linfo, world))
    proven = Bool[!claimed && line in eachindex(flags) && flags[line] & CC.IR_FLAG_EFFECT_FREE != 0 for line in lines]
    walk = Walk(ir, fill(NO_VALUE, length(ir.stmts)), proven, Dict{Place.Type, Set{Place.Type}}(), modules, world)
    return walk, lines, used, claimed
end

"""
Fact of call statement `index` in `walk` with its `events` (`CallFact`): write kinds include writes of package closures
it takes or calls. Closure kinds come from closure `writes`, fresh captured objects included. Compiler flags give
`effect_free`, `throws` and `terminates`. Builtin and foreign callee have no dispatch to open.
"""
function call_fact(walk::Walk, index::Integer, events::AbstractVector{Event}, writes::AbstractVector{ClosureWrite}, span::Span, used::Bool)::CallFact
    statement = walk.ir.stmts[index][:stmt]::Expr
    operands, callee = call_operands(statement), call_callee(walk, statement)
    flag = walk.ir.stmts[index][:flag]
    stand_in = any(operand -> holds_stand_in(operand_type(walk, operand)), operands)
    dispatched = statement.head === :call && !(constant_value(walk, statement.args[1]) isa Core.Builtin)
    open_dispatch = dispatched && !Base.isdispatchtuple(Tuple{Any[operand_type(walk, operand) for operand in statement.args]...})
    throws, terminates = flag & CC.IR_FLAG_NOTHROW == 0, flag & CC.IR_FLAG_TERMINATES != 0
    proven = proven_call(walk, index, statement, callee)
    return CallFact(span, callee, write_kinds(events)..., closure_kinds(writes)..., proven, throws, terminates, used, stand_in, open_dispatch)
end

"""Kinds of closure `writes` at any certainty, and kinds of exact writes."""
function closure_kinds(writes::AbstractVector{ClosureWrite})::Tuple{Vector{EffectKind.T}, Vector{EffectKind.T}}
    return sort!(unique!([write.kind for write in writes])), sort!(unique!([write.kind for write in writes if write.exact]))
end

"""Kinds of writes among `events` at any certainty, and kinds of definite writes."""
function write_kinds(events::AbstractVector{Event})::Tuple{Vector{EffectKind.T}, Vector{EffectKind.T}}
    writes = [event for event in events if event.write]
    return sort!(unique!([event.kind for event in writes])), sort!(unique!([event.kind for event in writes if event.confidence == Confidence.definite]))
end

"""Operands of call `statement`, callee first; foreign call gives its argument operands."""
function call_operands(statement::Expr)::Vector{Any}
    statement.head === :call && return statement.args
    return statement.args[6:(5 + length(statement.args[3]::Core.SimpleVector))]
end

"""
Callee of call `statement` in `walk` (`Callee`): builtin, foreign function, methods of up to `DISPATCH_LIMIT` matches,
else open. Splatted call and call of function stand-in, which stands for any function, are open.
"""
function call_callee(walk::Walk, statement::Expr)::Callee.Type
    statement.head === :foreigncall && return Callee.Foreign()
    head = constant_value(walk, statement.args[1])
    head === Core._apply_iterate && return Callee.Open()
    head isa Core.Builtin && return Callee.Builtin(head)
    holds_stand_in(operand_type(walk, statement.args[1])) && return Callee.Open()
    matches = call_matches(walk, statement)
    return isnothing(matches) ? Callee.Open() : methods_callee(Method[match.method for match in matches])
end

"""Method matches of call `statement` in `walk` by operand types, up to `DISPATCH_LIMIT`; `nothing` when more match."""
function call_matches(walk::Walk, statement::Expr)::Union{Nothing, Vector{Core.MethodMatch}}
    matches = Base._methods_by_ftype(Tuple{Any[operand_type(walk, operand) for operand in statement.args]...}, DISPATCH_LIMIT, walk.world)
    return matches isa Vector ? Core.MethodMatch[match for match in matches] : nothing
end

"""
Whether `@assume_effects` claims `:effect_free` on `method` or on block of `code`, code compiler infers for instance of
`method` (`nothing`: none). Compiler then trusts claim. Generated method gives code per instance, not `Method.source`.
"""
function claims_effect_free(method::Method, code::Union{Nothing, Core.CodeInfo})::Bool
    CC.decode_effects_override(method.purity).effect_free && return true
    return !isnothing(code) && any(flag -> CC.decode_statement_effects_override(flag).effect_free, code.ssaflags)
end

"""
`items` sorted by `key`, each key computed once: place text costs `repr`. Type parameter `F` makes Julia specialize on
`key`, so key vector is concrete: abstract one leaves `sortperm` open to invalidation.
"""
function text_order(items::AbstractVector{T}, key::F)::Vector{T} where {T, F <: Function}
    return items[sortperm(map(key, items))]
end

"""
Facts over all units of method, one per `key` in key order: definite in any unit decides. Key leads with source
position of fact, so order is source order.
"""
function surest(facts::AbstractVector{T}, key::F)::Vector{T} where {T <: Union{LoopWrite, SelfAlias, StatefulReuse, UnguardedHold, UnprovenIndex}, F <: Function}
    found = Dict{Tuple{String, Int, Int, Int, String}, T}()
    for fact in facts
        slot = key(fact)
        (!haskey(found, slot) || fact.confidence < found[slot].confidence) && (found[slot] = fact)
    end
    return T[found[slot] for slot in sort!(collect(keys(found)))]
end

"""Merge key of loop write: write bytes, loop start, writing function."""
loop_key(loop::LoopWrite)::Tuple{String, Int, Int, Int, String} = (loop.write.file, loop.write.first_byte, loop.write.last_byte, loop.loop.first_byte, loop.callee)

"""Merge key of self-alias call: call bytes, writing function."""
alias_key(call::SelfAlias)::Tuple{String, Int, Int, Int, String} = (call.call.file, call.call.first_byte, call.call.last_byte, 0, call.callee)

"""Merge key of stateful reuse: later event bytes, earlier event start, kinds of both events."""
reuse_key(reuse::StatefulReuse)::Tuple{String, Int, Int, Int, String} = (reuse.later.file, reuse.later.first_byte, reuse.later.last_byte, reuse.earlier.first_byte, string(reuse.earlier_escapes, reuse.later_escapes))

"""Merge key of hold throw skips: throwing statement bytes, acquire start, resource kind."""
hold_key(hold::UnguardedHold)::Tuple{String, Int, Int, Int, String} = (hold.throws.file, hold.throws.first_byte, hold.throws.last_byte, hold.acquire.first_byte, string(hold.kind))

"""Index facts of method from facts of its units: surest unproven index per call, each contract and call once."""
function merged_indices(units::AbstractVector{IndexFacts})::IndexFacts
    unproven, contracts, calls = UnprovenIndex[], IndexContract[], IndexCall[]
    for unit in units
        append!(unproven, unit.unproven)
        append!(contracts, unit.contracts)
        append!(calls, unit.calls)
    end
    return IndexFacts(surest(unproven, index_key), unique!(contracts), unique!(call -> (call.site, call.callees, call.arrays, call.claims), calls))
end

"""Merge key of unproven index: indexing call bytes."""
index_key(unproven::UnprovenIndex)::Tuple{String, Int, Int, Int, String} = (unproven.site.file, unproven.site.first_byte, unproven.site.last_byte, 0, "")

"""Call facts of one method by source statement and span."""
const Calls = Dict{Tuple{Int, Span}, CallFact}

"""Fact of call statement over two units of method: unit that may throw, writes, uses result or lacks proof decides."""
function merge_calls(first::CallFact, second::CallFact)::CallFact
    kinds, definite = sort!(union(first.kinds, second.kinds)), sort!(union(first.definite, second.definite))
    closure_kinds, closure_definite = sort!(union(first.closure_kinds, second.closure_kinds)), sort!(union(first.closure_definite, second.closure_definite))
    return CallFact(
        first.span, merge_callees(first.callee, second.callee), kinds, definite, closure_kinds, closure_definite, first.effect_free && second.effect_free,
        first.throws || second.throws, first.terminates && second.terminates, first.used || second.used, first.stand_in || second.stand_in,
        first.open_dispatch || second.open_dispatch,
    )
end

"""Add call facts `found` of unit to `calls` of its method (`merge_calls`)."""
function add_calls!(calls::Calls, found::UnitCalls)::Nothing
    for (key, fact) in found
        calls[key] = haskey(calls, key) ? merge_calls(calls[key], fact) : fact
    end
    return nothing
end

"""Call facts of `calls` in source order."""
call_order(calls::Calls)::Vector{CallFact} = [fact for (_, fact) in sort!(collect(calls); by = (((line, span), _),) -> (span.file, span.first_byte, span.last_byte, line))]

"""Effects `@assume_effects` on `method` claims, as `Base.EffectsOverride` field names in field order; block claims excluded."""
claimed_effects(method::Method)::Vector{Symbol} = (claim = CC.decode_effects_override(method.purity); Symbol[name for name in fieldnames(CC.EffectsOverride) if getfield(claim, name) === true])

"""Facts of all units of one method: holds throws skip, call facts, loop writes, self aliases, stateful reuses, index facts."""
const Collected = Tuple{Vector{UnguardedHold}, Calls, Vector{LoopWrite}, Vector{SelfAlias}, Vector{StatefulReuse}, Vector{IndexFacts}}

"""
Facts of methods of `package` from effects `records` of units in inference order and engine `verdicts`, and blind
spots (`effects.md`, Facts). Writes, reads and result aliases come from engine verdict; other facts merge over units.
Method in `incomplete`, or that stand-ins cut, is incomplete; no write with cut gives blind spot `CUT`. Method is
effect-free when compiler proves every unit effect-free. Method with record but no verdict throws.
"""
function method_facts(package::PackageFacts, incomplete::AbstractSet{Method}, records::AbstractVector{Pair{Method, Union{Nothing, UnitEffects}}}, verdicts::AbstractVector{Summaries.MethodVerdict})::Tuple{EffectsFacts, Vector{BlindSpot}}
    spots, verdict_of = BlindSpot[], IdDict{Method, Summaries.MethodVerdict}(verdict.site.method => verdict for verdict in verdicts)
    found, free, cuts, new_results = IdDict{Method, Collected}(), IdDict{Method, Bool}(), IdDict{Method, Span}(), IdDict{Method, Bool}()
    for (method, record) in records
        isnothing(record) && continue
        append!(spots, record.spots)
        record.verdict || continue
        unguarded, calls, loops, selves, reuses, indices = get!(() -> (UnguardedHold[], Calls(), LoopWrite[], SelfAlias[], StatefulReuse[], IndexFacts[]), found, method)
        append!(unguarded, record.unguarded)
        add_calls!(calls, record.calls)
        append!(loops, record.loop_writes)
        append!(selves, record.self_aliases)
        append!(reuses, record.stateful_reuses)
        push!(indices, record.indices)
        free[method] = get(free, method, true) && record.effect_free
        new_results[method] = get(new_results, method, false) || record.new_result
        isnothing(record.cut) || haskey(cuts, method) || (cuts[method] = something(record.cut))
    end
    methods = MethodEffects[]
    for site in package.methods
        haskey(found, site.method) || continue
        unguarded, calls, loops, selves, reuses, indices = found[site.method]
        verdict = get(verdict_of, site.method, nothing)
        isnothing(verdict) && throw(ArgumentError("engine gives no verdict for $(site.method), which has name tier record"))
        complete = !(site.method in incomplete) && !haskey(cuts, site.method) && verdict.complete
        effects = MethodEffects(
            site, verdict.writes, verdict.reads, verdict.aliases, surest(unguarded, hold_key),
            call_order(calls), surest(loops, loop_key), surest(selves, alias_key), surest(reuses, reuse_key), merged_indices(indices), complete, free[site.method], new_results[site.method],
            name_writes(site.method), claimed_effects(site.method),
        )
        push!(methods, effects)
        # Write keeps its certainty with cut; only method without write goes to coverage line.
        haskey(cuts, site.method) && isempty(effects.writes) && push!(spots, BlindSpot(CUT, cuts[site.method]))
    end
    return EffectsFacts(methods), unique!(spots)
end

"""
Records of one `effects` stage run (`effects_facts`): facts, blind spots, name tier record and engine verdict of each
typed unit for method store (`nothing` for unit whose instance earlier unit holds), compiler edges of offset inference
per typed unit (`unit_effects`), name tier records of all units in inference order with their methods
(`ordered_records`), new library cache entries, and keys of library entries that hit.
"""
struct StageRun
    facts::EffectsFacts
    spots::Vector{BlindSpot}
    fresh::Vector{Union{Nothing, UnitEffects}}
    verdicts::Vector{Union{Nothing, Summaries.UnitVerdict}}
    edges::Vector{Union{Nothing, Vector{Any}}}
    ordered::Vector{Pair{Method, Union{Nothing, UnitEffects}}}
    library::Summaries.Library
    hits::Set{String}
end

"""
`effects` stage run on `package` from inference `units` (`StageRun`), with `library` cache of engine summaries
(`engine.md`, Solve and cache). Stored units give their kept records. Crash `journal` records offset inferences and
native inference of library instances; `nothing` none.
"""
function effects_facts(package::PackageFacts, units::Units, journal::Union{Nothing, Inference.Journal}, library::Summaries.Library)::StageRun
    world = Base.get_world_counter()
    interpreter, modules, seen = CC.NativeInterpreter(world), Set{Module}(package.modules), Base.IdSet{Core.MethodInstance}()
    fresh, edges = Union{Nothing, UnitEffects}[], Union{Nothing, Vector{Any}}[]
    for typed in units.typed
        record, read = typed.frame.linfo in seen ? (nothing, Any[]) : unit_effects(typed, modules, interpreter, world, journal)
        push!(fresh, record)
        push!(edges, read)
        push!(seen, typed.frame.linfo)
    end
    kept = Union{Nothing, Tuple{UnitEffects, Summaries.UnitVerdict}}[unit_record(unit.effects, world) for unit in units.stored]
    stored = Union{Nothing, UnitEffects}[isnothing(pair) ? nothing : first(pair) for pair in kept]
    verdicts, engine_spots, fresh_verdicts, entries, hits = Summaries.cached_effects(package, units, Union{Nothing, Summaries.UnitVerdict}[isnothing(pair) ? nothing : last(pair) for pair in kept], journal, library)
    ordered = ordered_records(units, fresh, stored)
    facts, spots = method_facts(package, units.incomplete, ordered, verdicts)
    return StageRun(facts, unique!([spots; engine_spots]), fresh, fresh_verdicts, edges, ordered, entries, hits)
end

"""
Store `used` where each entry without effects record takes one: typed unit of `units` its name record and engine
verdict in effects `run`, other unit (no code) `nothing`. Filled entry also reads methods behind compiler edges of its
effects stage; entry drops when they are unknown (`Inference.with_edges!`). Generators run under crash `journal`.
Stored entries keep theirs.
"""
function with_records(used::Inference.Store, units::Inference.Units, run::StageRun, files::AbstractVector{SyntaxFile}, package::PackageFacts, journal::Union{Nothing, Inference.Journal})::Inference.Store
    bytes, read = Dict{String, Vector{UInt8}}(), Dict{String, Union{Nothing, Vector{Any}}}()
    for (typed, record, verdict, unit_edges) in zip(units.typed, run.fresh, run.verdicts, run.edges)
        key = Inference.entry_key(typed.site.method, typed.signature)
        # Unit that repeats method instance of earlier unit has no record of its own.
        isnothing(record) && haskey(bytes, key) && continue
        bytes[key], read[key] = record_bytes(record, verdict), unit_edges
    end
    none, by_path, memo = record_bytes(nothing, nothing), Dict(file.path => file for file in files), Inference.StoreMemo(package, IdDict{Method, String}())
    filled(key::String, entry::Inference.Entry)::Union{Nothing, Inference.Entry} = Inference.with_edges!(memo, Inference.Entry(entry.file, entry.methods, entry.staged, entry.names, entry.inferred, get(bytes, key, none)), get(read, key, Any[]), by_path, journal)
    store = Inference.Store()
    for (key, entry) in used
        kept = isempty(entry.effects) ? filled(key, entry) : entry
        isnothing(kept) || (store[key] = kept)
    end
    return store
end
