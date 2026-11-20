using ..Signatures: Provenance

"""Span of IR statement `cause` of unit `typed` with `code`: its source statement span, else method span."""
function cause_span(typed::TypedCode, code::Code, cause::Int)::Span
    line = cause in eachindex(code.lines) ? code.lines[cause] : 0
    return line in eachindex(typed.spans) ? typed.spans[line] : typed.site.span
end

"""Blind spot cause of open dispatch whose open types Corset chose (`effects.md`, Provenance)."""
const OPAQUE_DATA = "open dispatch on opaque data"

"""
Provenance of `code` doubt with `sources` in unit with argument `provenance` (`effects.md`, Provenance): `code` when
doubt is in code itself or any source argument is code; else `opaque` when any source is; else `opt_out`.
"""
function source_provenance(sources::Sources, provenance::Vector{Provenance.T})::Provenance.T
    sources & INHERENT == 0 || return Provenance.code
    found = sources & OPAQUE == 0 ? Provenance.opt_out : Provenance.opaque
    for position in 1:LAST_PARAMETER
        sources & parameter_source(position) == 0 && continue
        kind = position <= length(provenance) ? provenance[position] : Provenance.code
        kind == Provenance.code && return Provenance.code
        kind == Provenance.opaque && (found = Provenance.opaque)
    end
    return found
end

"""
Accesses of unit `effects` with doubt below blind, and blind accesses, with cause spans from `span_of`. Argument
`provenance` judges `code` doubt: opaque gives blind access (`OPAQUE_DATA`); opt-out gives no access.
"""
function unit_accesses(effects::Accesses, span_of::Function, provenance::Vector{Provenance.T})::Tuple{Vector{Access}, Vector{BlindAccess}}
    accesses, blind = Access[], BlindAccess[]
    for ((place, below, effect_kind), effect) in effects
        span, level = span_of(effect.cause), level_of(effect.doubt)
        judged = level == Level.code ? source_provenance(sources_of(effect.doubt), provenance) : Provenance.code
        if level == Level.blind
            push!(blind, BlindAccess(place, below, effect_kind, BlindSpot(effect.reason, span)))
        elseif judged == Provenance.opaque
            push!(blind, BlindAccess(place, below, effect_kind, BlindSpot(OPAQUE_DATA, span)))
        elseif judged == Provenance.code
            push!(accesses, Access(place, below, effect_kind, level == Level.none ? Confidence.definite : Confidence.possible, span))
        end
    end
    return accesses, blind
end

"""
Places result of `summary` aliases: caller places and `Elsewhere` (unknown object) it reaches, through slots of fresh
objects too. `view(A, 1:2)` result holds `A`.
"""
function result_aliases(summary::Summary)::Vector{Place.Type}
    found, seen, pending = Place.Type[], Set{Node.Type}(), collect(keys(summary.result))
    while !isempty(pending)
        node = pop!(pending)
        node in seen && continue
        push!(seen, node)
        @match node begin
            Node.Placed(place) => push!(found, place)
            Node.Outside() => push!(found, Place.At(Root.Elsewhere(), Step.Type[]))
            Node.Fresh(_) => append!(pending, node_contents(summary, node))
        end
    end
    return found
end

"""Nodes in every slot of `node` in exported graph of `summary`: fields, memory backing and unknown slot."""
function node_contents(summary::Summary, node::Node.Type)::Vector{Node.Type}
    found = Node.Type[node for ((holder, _), nodes) in summary.edges if holder == node for node in keys(nodes)]
    append!(found, keys(get(summary.backing, node, Nodes())), keys(get(summary.spread, node, Nodes())))
    return found
end

"""
Lock writes of `summary`, cause spans from `span_of` and place kinds from `kind_of` (`effects.md`, Release balance): lock
or semaphore count not 0 at normal exit on caller place. Exact count gives definite write, join gives `possible`, release
pattern gives blind write. Lock inside `IO` gives IO. Fresh lock stays local.
"""
function lock_writes(summary::Summary, span_of::Function, kind_of::Function)::Tuple{Vector{Access}, Vector{BlindAccess}}
    writes, blind = Access[], BlindAccess[]
    for ((node, resource), hold) in summary.held
        resource == Resource.lock || continue
        place = @match node begin
            Node.Placed(place) => place
            Node.Outside() => Place.At(Root.Elsewhere(), Step.Type[])
            Node.Fresh(_) => nothing
        end
        isnothing(place) && continue
        span, found = span_of(hold.cause), kind_of(place)::EffectKind.T
        # Lock of field whose type inference widened is lock still.
        kind = found == EffectKind.memory ? EffectKind.synchronization : found
        if hold.level == Level.blind
            push!(blind, BlindAccess(place, false, kind, BlindSpot(hold.reason, span)))
        else
            push!(writes, Access(place, false, kind, hold.level == Level.none ? Confidence.definite : Confidence.possible, span))
        end
    end
    return writes, blind
end

"""
Holds throws skip in `summary` (F98), with spans from `span_of`: exact count gives definite, join gives `possible`.
Release pattern Corset cannot count gives blind spot.
"""
function unguarded_holds(summary::Summary, span_of::Function)::Tuple{Vector{UnguardedHold}, Vector{BlindSpot}}
    holds, spots = UnguardedHold[], BlindSpot[]
    for (; hold, throws) in values(summary.unguarded)
        if hold.level == Level.blind
            push!(spots, BlindSpot(hold.reason, span_of(hold.cause)))
        else
            push!(holds, UnguardedHold(span_of(hold.cause), span_of(throws), hold.level == Level.none ? Confidence.definite : Confidence.possible))
        end
    end
    return holds, spots
end

"""Order key of access to `place` with `below` and `kind`: places sort by text."""
place_key(place::Place.Type, below::Bool, kind::EffectKind.T)::Tuple{String, Bool, EffectKind.T} = (repr(place), below, kind)

"""Worst access per place, coverage and kind over `accesses` of all units: definite beats possible; first cause stays."""
function worst(accesses::Vector{Access})::Vector{Access}
    found = Dict{Tuple{Place.Type, Bool, EffectKind.T}, Access}()
    for access in accesses
        key = (access.place, access.below, access.kind)
        old = get(found, key, nothing)
        (isnothing(old) || access.confidence < old.confidence) && (found[key] = access)
    end
    return sort!(collect(values(found)); by = access -> place_key(access.place, access.below, access.kind))
end

"""Blind accesses of all units, each once, by place."""
blind_order(accesses::Vector{BlindAccess})::Vector{BlindAccess} = sort!(unique!(accesses); by = access -> place_key(access.place, access.below, access.kind))

"""Blind spot cause of method whose verdict writes nothing on path stand-ins cut (`effects.md`, Stand-in cuts)."""
const CUT = "stand-in cuts path"

"""Span of cut that reaches root unit `typed`: first own cut statement, else first call whose callee summary carries cut."""
function cut_span(run::Run, typed::TypedCode, root::Variant)::Span
    isempty(typed.cuts) || return typed.spans[first(typed.cuts)]
    code = run.codes[root]
    index = findfirst(callees -> any(callee -> run.summaries[callee].cut, callees), code.callees)
    # Record that root resolves can carry cut that no direct callee shows.
    return isnothing(index) ? typed.site.span : cause_span(typed, code, index)
end

"""Call facts of one method by source statement and span."""
const Calls = Dict{Tuple{Int, Span}, CallFact}

"""
Accesses of all units of one method: writes, reads, blind writes, blind reads, result aliases, holds throws skip, call
facts.
"""
const Collected = Tuple{Vector{Access}, Vector{Access}, Vector{BlindAccess}, Vector{BlindAccess}, Vector{Place.Type}, Vector{UnguardedHold}, Calls}

"""Methods of `callee` that dispatch reaches; `nothing` for other callee."""
callee_methods(callee::Callee.Type)::Union{Nothing, Vector{Method}} = @match callee begin
    Callee.Methods(methods) => methods
    _ => nothing
end

"""Callee of call statement over two units of method: methods of both; open when either is other callee."""
function merge_callees(first::Callee.Type, second::Callee.Type)::Callee.Type
    first == second && return first
    left, right = callee_methods(first), callee_methods(second)
    return isnothing(left) || isnothing(right) ? Callee.Open() : Callee.Methods(union(left, right))
end

"""Fact of call statement over two units of method (`CallFact`)."""
function merge_calls(first::CallFact, second::CallFact)::CallFact
    kinds = sort!(union(first.kinds, second.kinds))
    return CallFact(first.span, merge_callees(first.callee, second.callee), kinds, first.throws || second.throws, first.terminates && second.terminates, first.used || second.used)
end

"""Add call facts `found` of unit to `calls` of its method: units of method merge (`merge_calls`)."""
function add_calls!(calls::Calls, found::UnitCalls)::Nothing
    for (key, fact) in found
        calls[key] = haskey(calls, key) ? merge_calls(calls[key], fact) : fact
    end
    return nothing
end

"""Call facts of `calls` in source order."""
call_order(calls::Calls)::Vector{CallFact} = [fact for (_, fact) in sort!(collect(calls); by = (((line, span), _),) -> (span.file, span.first_byte, span.last_byte, line))]

"""
`effects` stage facts of `package` from inference `units`, and blind spots, without library cache (`cached_effects`).
Crash `journal` records native inference of instances outside units.
"""
effects_facts(package::PackageFacts, units::Units, journal::Union{Nothing, Journal})::Tuple{EffectsFacts, Vector{BlindSpot}} = cached_effects(package, units, journal, Library())[1:2]

"""
`effects` stage facts of `package` from inference `units` and blind spots, with `library` cache (`effects.md`, Solve and
cache). Also effects record of each typed unit for method store, `nothing` for unit whose instance earlier unit holds,
and new library cache entries. Run that skipped crashed instance gives no entries: its blind spot holds here only.
Crash `journal` records native inference of instances outside units.
"""
function cached_effects(package::PackageFacts, units::Units, journal::Union{Nothing, Journal}, library::Library)::Tuple{EffectsFacts, Vector{BlindSpot}, Vector{Union{Nothing, UnitEffects}}, Library}
    run = start_run(journal, package.modules, library)
    typed_of = IdDict{Core.MethodInstance, TypedCode}()
    for typed in units.typed
        haskey(typed_of, typed.frame.linfo) && continue
        typed_of[typed.frame.linfo] = typed
        run.cuts[typed.frame.linfo] = !isempty(typed.cuts)
    end
    stored = Union{Nothing, UnitEffects}[unit_record(unit.effects, run.world) for unit in units.stored]
    # Stored unit keeps cut of own code and unit body, so callers solve as in run that inferred it.
    for (unit, record) in zip(units.stored, stored)
        isnothing(record) && continue
        instance = something(Inference.instance(unit.site.method, unit.signature))
        haskey(typed_of, instance) || (run.cuts[instance] = record.own_cut; push!(run.cache.stored, instance))
    end
    roots = Variant[(typed.frame.linfo, Pair{Int, Any}[]) for typed in units.typed if typed_of[typed.frame.linfo] === typed]
    # Every unit cut is known before first shortcut check walks callees; unit order keeps first callers fixed.
    for (instance, _) in roots
        run.bodies[instance] = unit_body(run, typed_of[instance].frame, run.cuts[instance])
    end
    solve!(run, roots)
    fresh = Union{Nothing, UnitEffects}[typed_of[typed.frame.linfo] === typed ? unit_effects(run, typed, (typed.frame.linfo, Pair{Int, Any}[])) : nothing for typed in units.typed]
    facts, spots = method_facts(package, units.incomplete, ordered_records(units, fresh, stored))
    crashed = !isnothing(journal) && !isempty(journal.crashed)
    return facts, spots, fresh, crashed ? Library() : library_entries(run)
end

"""
Facts of methods of `package` from effects `records` of units in inference order, and blind spots: worst over units of
method (`effects.md`, Units and Facts). Method in `incomplete`, or that stand-ins cut, is incomplete; verdict none with
cut gives blind spot `CUT`.
"""
function method_facts(package::PackageFacts, incomplete::Set{Method}, records::Vector{Pair{Method, Union{Nothing, UnitEffects}}})::Tuple{EffectsFacts, Vector{BlindSpot}}
    spots = BlindSpot[]
    found, closed, cuts = IdDict{Method, Collected}(), IdDict{Method, Bool}(), IdDict{Method, Span}()
    for (method, record) in records
        isnothing(record) && continue
        append!(spots, record.spots)
        record.verdict || continue
        writes, reads, blind_writes, blind_reads, aliases, unguarded, calls = get!(() -> (Access[], Access[], BlindAccess[], BlindAccess[], Place.Type[], UnguardedHold[], Calls()), found, method)
        append!(writes, record.writes)
        append!(reads, record.reads)
        append!(blind_writes, record.blind_writes)
        append!(blind_reads, record.blind_reads)
        append!(aliases, record.aliases)
        append!(unguarded, record.unguarded)
        add_calls!(calls, record.calls)
        closed[method] = get(closed, method, false) || record.closed_world
        isnothing(record.cut) || haskey(cuts, method) || (cuts[method] = something(record.cut))
    end
    methods = MethodEffects[]
    for site in package.methods
        haskey(found, site.method) || continue
        writes, reads, blind_writes, blind_reads, aliases, unguarded, calls = found[site.method]
        complete = !(site.method in incomplete) && !haskey(cuts, site.method)
        effects = MethodEffects(
            site, worst(writes), worst(reads), blind_order(blind_writes), blind_order(blind_reads), sort!(unique!(aliases); by = repr), sort!(unique!(unguarded); by = repr),
            call_order(calls), complete, closed[site.method],
        )
        push!(methods, effects)
        append!(spots, (access.spot for access in [effects.blind_writes; effects.blind_reads]))
        # Write keeps its certainty with cut; only verdict none goes to coverage line.
        haskey(cuts, site.method) && isempty(effects.writes) && isempty(effects.blind_writes) && push!(spots, BlindSpot(CUT, cuts[site.method]))
    end
    return EffectsFacts(methods), unique!(spots)
end
