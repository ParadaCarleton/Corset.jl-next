# Unit records and method facts of name tier (`effects.md`, Units and IR, Facts).

"""Blind spot cause of unit that always throws on stand-ins: it shows no behavior of declared signature."""
const ALWAYS_THROWS = "always throws on stand-ins"

"""Blind spot cause of method whose facts hold no write on path stand-ins cut (`effects.md`, Stand-in cuts)."""
const CUT = "stand-in cuts path"

"""Most methods call statement callee joins: compiler `max_methods`. More gives open callee."""
const DISPATCH_LIMIT = 3

"""
Effects record of unit `typed` (`effects.md`, Units and IR): events of each IR statement, result aliases and call
facts. `effect_free`: compiler proves unit writes nothing caller sees; stand-in signature, claim in method, or claim of
direct callee gives no proof.
Unit that always throws on stand-ins gives no verdict, only its blind spot.
"""
function unit_effects(typed::TypedCode, modules::AbstractSet{Module}, interpreter::CC.NativeInterpreter, world::UInt)::UnitEffects
    cut = isempty(typed.cuts) ? nothing : typed.spans[first(typed.cuts)]
    typed.result === Union{} && return UnitEffects(false, Access[], Access[], Place.Type[], UnguardedHold[], UnitCalls(), LoopWrite[], SelfAlias[], StatefulReuse[], [BlindSpot(ALWAYS_THROWS, typed.site.span)], false, cut)
    walk, lines, used, claimed = unit_walk(typed, modules, interpreter, world)
    ir = walk.ir
    walk_values!(walk, 2 * length(ir.stmts) + 10)
    users = statement_users(ir)
    writes, reads, aliases, calls, callee_claimed = Access[], Access[], Set{Place.Type}(), UnitCalls(), false
    spans = Span[line in eachindex(typed.spans) ? typed.spans[line] : typed.site.span for line in lines]
    for index in 1:length(ir.stmts)
        line, span = lines[index], spans[index]
        events, invoked = statement_events(walk, index)
        foreach(event -> push!(event.write ? writes : reads, Access(event.place, event.below, event.kind, event.confidence, span)), events)
        statement = ir.stmts[index][:stmt]
        statement isa Core.ReturnNode && isdefined(statement, :val) && union!(aliases, held(operand_value(walk, statement.val)))
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
    return UnitEffects(true, writes, reads, text_order(collect(aliases), repr), UnguardedHold[], calls, loops, self_aliases(walk, spans), reuses, [loop_spots; reuse_spots], effect_free, cut)
end

"""
Walk of unit `typed` before `walk_values!`, source line of each IR statement, use of each source line, and whether method
claims `:effect_free`.
"""
function unit_walk(typed::TypedCode, modules::AbstractSet{Module}, interpreter::CC.NativeInterpreter, world::UInt)::Tuple{Walk, Vector{Int}, Vector{Bool}, Bool}
    ir, lines, used = frame_ir(typed.frame, interpreter, Bool[call_statement(statement) for statement in typed.frame.src.code])
    # Source flags keep compiler `effect_free`, which `frame_ir` clears on kept calls. Claim in method voids proof.
    # Inferred flags reuse claim bits, so claim reads code before inference.
    flags, claimed = typed.frame.src.ssaflags, claims_effect_free(typed.site.method, CC.retrieve_code_info(typed.frame.linfo, world))
    proven = Bool[!claimed && line in eachindex(flags) && flags[line] & CC.IR_FLAG_EFFECT_FREE != 0 for line in lines]
    walk = Walk(ir, fill(NO_VALUE, length(ir.stmts)), proven, Dict{Place.Type, Set{Place.Type}}(), IdDict{Any, Bool}(), modules, IdDict{Any, Vector{ClosureWrite}}(), IdDict{Union{Method, Core.MethodInstance}, Bool}(), world)
    return walk, lines, used, claimed
end

"""
Fact of call statement `index` in `walk` with its `events` (`CallFact`): write kinds include writes of package closures
it takes or calls. Closure kinds come from closure `writes`, fresh captured objects included. Compiler flags give
`throws` and `terminates`.
"""
function call_fact(walk::Walk, index::Integer, events::AbstractVector{Event}, writes::AbstractVector{ClosureWrite}, span::Span, used::Bool)::CallFact
    statement = walk.ir.stmts[index][:stmt]::Expr
    operands = call_operands(statement)
    flag = walk.ir.stmts[index][:flag]
    stand_in = any(operand -> holds_stand_in(operand_type(walk, operand)), operands)
    return CallFact(span, call_callee(walk, statement), write_kinds(events)..., closure_kinds(writes)..., flag & CC.IR_FLAG_NOTHROW == 0, flag & CC.IR_FLAG_TERMINATES != 0, used, stand_in)
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

"""Key of access for worst merge and order: place text, coverage, kind."""
place_key(place::Place.Type, below::Bool, kind::EffectKind.T)::Tuple{String, Bool, EffectKind.T} = (repr(place), below, kind)

"""Worst access per place, coverage and kind over `accesses` of all units: definite beats possible; first cause stays."""
function worst(accesses::AbstractVector{Access})::Vector{Access}
    found = Dict{Tuple{Place.Type, Bool, EffectKind.T}, Access}()
    for access in accesses
        key = (access.place, access.below, access.kind)
        old = get(found, key, nothing)
        (isnothing(old) || access.confidence < old.confidence) && (found[key] = access)
    end
    return text_order(collect(values(found)), access -> place_key(access.place, access.below, access.kind))
end

"""
Facts over all units of method, one per `key` in key order: definite in any unit decides. Key leads with source
position of fact, so order is source order.
"""
function surest(facts::AbstractVector{T}, key::F)::Vector{T} where {T <: Union{LoopWrite, SelfAlias, StatefulReuse}, F <: Function}
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

"""Call facts of one method by source statement and span."""
const Calls = Dict{Tuple{Int, Span}, CallFact}

"""Callee of call statement over two units of method: methods of both; open when either is other callee."""
function merge_callees(first::Callee.Type, second::Callee.Type)::Callee.Type
    first == second && return first
    left, right = callee_methods(first), callee_methods(second)
    return isnothing(left) || isnothing(right) ? Callee.Open() : methods_callee([left; right])
end

"""Fact of call statement over two units of method: unit that may throw, writes or uses result decides."""
function merge_calls(first::CallFact, second::CallFact)::CallFact
    kinds, definite = sort!(union(first.kinds, second.kinds)), sort!(union(first.definite, second.definite))
    closure_kinds, closure_definite = sort!(union(first.closure_kinds, second.closure_kinds)), sort!(union(first.closure_definite, second.closure_definite))
    return CallFact(first.span, merge_callees(first.callee, second.callee), kinds, definite, closure_kinds, closure_definite, first.throws || second.throws, first.terminates && second.terminates, first.used || second.used, first.stand_in || second.stand_in)
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

"""
Effects record of each unit in inference order, with its method: typed unit takes its record in `fresh`, stored unit
(`Units.stored`) its record in `stored`. Order keeps first cause per access (`worst`), as run that infers all.
"""
function ordered_records(units::Units, fresh::AbstractVector{Union{Nothing, UnitEffects}}, stored::AbstractVector{Union{Nothing, UnitEffects}})::Vector{Pair{Method, Union{Nothing, UnitEffects}}}
    positions = [[(index, 0) for index in eachindex(units.typed)]; [(unit.position, 1) for unit in units.stored]]
    methods = Method[[typed.site.method for typed in units.typed]; [unit.site.method for unit in units.stored]]
    records = Union{Nothing, UnitEffects}[fresh; stored]
    return [methods[index] => records[index] for index in sortperm(positions)]
end

"""
Accesses of all units of one method: writes, reads, result aliases, holds throws skip, call facts, loop writes, self
aliases, stateful reuses.
"""
const Collected = Tuple{Vector{Access}, Vector{Access}, Vector{Place.Type}, Vector{UnguardedHold}, Calls, Vector{LoopWrite}, Vector{SelfAlias}, Vector{StatefulReuse}}

"""
Facts of methods of `package` from effects `records` of units in inference order, and blind spots: worst over units of
method (`effects.md`, Facts). Method in `incomplete`, or that stand-ins cut, is incomplete; no write with cut gives
blind spot `CUT`. Method is effect-free when compiler proves every unit effect-free.
"""
function method_facts(package::PackageFacts, incomplete::AbstractSet{Method}, records::AbstractVector{Pair{Method, Union{Nothing, UnitEffects}}})::Tuple{EffectsFacts, Vector{BlindSpot}}
    spots = BlindSpot[]
    found, free, cuts = IdDict{Method, Collected}(), IdDict{Method, Bool}(), IdDict{Method, Span}()
    for (method, record) in records
        isnothing(record) && continue
        append!(spots, record.spots)
        record.verdict || continue
        writes, reads, aliases, unguarded, calls, loops, selves, reuses = get!(() -> (Access[], Access[], Place.Type[], UnguardedHold[], Calls(), LoopWrite[], SelfAlias[], StatefulReuse[]), found, method)
        append!(writes, record.writes)
        append!(reads, record.reads)
        append!(aliases, record.aliases)
        append!(unguarded, record.unguarded)
        add_calls!(calls, record.calls)
        append!(loops, record.loop_writes)
        append!(selves, record.self_aliases)
        append!(reuses, record.stateful_reuses)
        free[method] = get(free, method, true) && record.effect_free
        isnothing(record.cut) || haskey(cuts, method) || (cuts[method] = something(record.cut))
    end
    methods = MethodEffects[]
    for site in package.methods
        haskey(found, site.method) || continue
        writes, reads, aliases, unguarded, calls, loops, selves, reuses = found[site.method]
        complete = !(site.method in incomplete) && !haskey(cuts, site.method)
        effects = MethodEffects(
            site, worst(writes), worst(reads), text_order(unique!(aliases), repr), text_order(unique!(unguarded), repr),
            call_order(calls), surest(loops, loop_key), surest(selves, alias_key), surest(reuses, reuse_key), complete, free[site.method], claimed_effects(site.method),
        )
        push!(methods, effects)
        # Write keeps its certainty with cut; only method without write goes to coverage line.
        haskey(cuts, site.method) && isempty(effects.writes) && push!(spots, BlindSpot(CUT, cuts[site.method]))
    end
    return EffectsFacts(methods), unique!(spots)
end

"""
`effects` stage facts of `package` from inference `units`, blind spots, and effects record of each typed unit for method
store: `nothing` for unit whose instance earlier unit holds. Stored units give their kept records.
"""
function effects_facts(package::PackageFacts, units::Units)::Tuple{EffectsFacts, Vector{BlindSpot}, Vector{Union{Nothing, UnitEffects}}}
    world = Base.get_world_counter()
    interpreter, modules, seen = CC.NativeInterpreter(world), Set{Module}(package.modules), Base.IdSet{Core.MethodInstance}()
    fresh = Union{Nothing, UnitEffects}[]
    for typed in units.typed
        push!(fresh, typed.frame.linfo in seen ? nothing : unit_effects(typed, modules, interpreter, world))
        push!(seen, typed.frame.linfo)
    end
    stored = Union{Nothing, UnitEffects}[unit_record(unit.effects, world) for unit in units.stored]
    facts, spots = method_facts(package, units.incomplete, ordered_records(units, fresh, stored))
    return facts, spots, fresh
end
