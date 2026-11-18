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
    for ((place, below), effect) in effects
        span, level = span_of(effect.cause), level_of(effect.doubt)
        kind = level == Level.code ? source_provenance(sources_of(effect.doubt), provenance) : Provenance.code
        if level == Level.blind
            push!(blind, BlindAccess(place, below, BlindSpot(effect.reason, span)))
        elseif kind == Provenance.opaque
            push!(blind, BlindAccess(place, below, BlindSpot(OPAQUE_DATA, span)))
        elseif kind == Provenance.code
            push!(accesses, Access(place, below, level == Level.none ? Confidence.definite : Confidence.possible, span))
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

"""Order key of access to `place` with `below`: places sort by text."""
place_key(place::Place.Type, below::Bool)::Tuple{String, Bool} = (repr(place), below)

"""Worst access per place and coverage over `accesses` of all units: definite beats possible; first cause stays."""
function worst(accesses::Vector{Access})::Vector{Access}
    found = Dict{Tuple{Place.Type, Bool}, Access}()
    for access in accesses
        key = (access.place, access.below)
        old = get(found, key, nothing)
        (isnothing(old) || access.confidence < old.confidence) && (found[key] = access)
    end
    return sort!(collect(values(found)); by = access -> place_key(access.place, access.below))
end

"""Blind accesses of all units, each once, by place."""
blind_order(accesses::Vector{BlindAccess})::Vector{BlindAccess} = sort!(unique!(accesses); by = access -> place_key(access.place, access.below))

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

"""Accesses of all units of one method: writes, reads, blind writes, blind reads, result aliases."""
const Collected = Tuple{Vector{Access}, Vector{Access}, Vector{BlindAccess}, Vector{BlindAccess}, Vector{Place.Type}}

"""
`effects` stage facts of `package` from inference `units`, and blind spots: summary per package method over its units
(`effects.md`, Units and Facts). Method that stand-ins cut is incomplete; verdict none with cut gives blind spot `CUT`.
Crash `journal` records native inference of instances outside units.
"""
function effects_facts(package::PackageFacts, units::Units, journal::Union{Nothing, Journal})::Tuple{EffectsFacts, Vector{BlindSpot}}
    run = start_run(journal, package.modules)
    typed_of = IdDict{Core.MethodInstance, TypedCode}()
    for typed in units.typed
        haskey(typed_of, typed.frame.linfo) && continue
        typed_of[typed.frame.linfo] = typed
        run.cuts[typed.frame.linfo] = !isempty(typed.cuts)
    end
    roots = Variant[(typed.frame.linfo, Pair{Int, Any}[]) for typed in units.typed if typed_of[typed.frame.linfo] === typed]
    # Every unit cut is known before first shortcut check walks callees; unit order keeps first callers fixed.
    for (instance, _) in roots
        run.bodies[instance] = instance_body(run, typed_of[instance].frame, run.cuts[instance])
    end
    solve!(run, roots)
    spots = BlindSpot[]
    found, closed, cuts = IdDict{Method, Collected}(), IdDict{Method, Bool}(), IdDict{Method, Span}()
    for root in roots
        typed = typed_of[first(root)]
        # Unit that always throws on stand-ins shows no behavior of declared signature.
        typed.result === Union{} && (push!(spots, BlindSpot("always throws on stand-ins", typed.site.span)); continue)
        # Shortcut root has no code; its summary holds no access to give span.
        summary = root_summary(run, root)
        span_of(cause::Int)::Span = cause_span(typed, run.codes[root], cause)
        writes, reads, blind_writes, blind_reads, aliases = get!(() -> (Access[], Access[], BlindAccess[], BlindAccess[], Place.Type[]), found, typed.site.method)
        unit_writes, unit_blind_writes = unit_accesses(summary.writes, span_of, typed.provenance)
        unit_reads, unit_blind_reads = unit_accesses(summary.reads, span_of, typed.provenance)
        append!(writes, unit_writes)
        append!(reads, unit_reads)
        append!(blind_writes, unit_blind_writes)
        append!(blind_reads, unit_blind_reads)
        append!(aliases, result_aliases(summary))
        closed[typed.site.method] = get(closed, typed.site.method, false) || summary.closed_world
        summary.cut && !haskey(cuts, typed.site.method) && (cuts[typed.site.method] = cut_span(run, typed, root))
    end
    methods = MethodEffects[]
    for site in package.methods
        haskey(found, site.method) || continue
        writes, reads, blind_writes, blind_reads, aliases = found[site.method]
        complete = !(site.method in units.incomplete) && !haskey(cuts, site.method)
        effects = MethodEffects(site, worst(writes), worst(reads), blind_order(blind_writes), blind_order(blind_reads), sort!(unique!(aliases); by = repr), complete, closed[site.method])
        push!(methods, effects)
        append!(spots, (access.spot for access in [effects.blind_writes; effects.blind_reads]))
        # Write keeps its certainty with cut; only verdict none goes to coverage line.
        haskey(cuts, site.method) && isempty(effects.writes) && isempty(effects.blind_writes) && push!(spots, BlindSpot(CUT, cuts[site.method]))
    end
    return EffectsFacts(methods), unique!(spots)
end
