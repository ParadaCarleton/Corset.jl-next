"""Span of IR statement `cause` of unit `typed` with `code`: its source statement span, else method span."""
function cause_span(typed::TypedCode, code::Code, cause::Int)::Span
    line = cause in eachindex(code.lines) ? code.lines[cause] : 0
    return line in eachindex(typed.spans) ? typed.spans[line] : typed.site.span
end

"""Accesses of unit `effects` with doubt below blind, and blind accesses, with cause spans from `span_of`."""
function unit_accesses(effects::Accesses, span_of::Function)::Tuple{Vector{Access}, Vector{BlindAccess}}
    accesses, blind = Access[], BlindAccess[]
    for ((place, below), effect) in effects
        span = span_of(effect.cause)
        if effect.doubt == Doubt.blind
            push!(blind, BlindAccess(place, below, BlindSpot(effect.reason, span)))
        else
            push!(accesses, Access(place, below, effect.doubt == Doubt.none ? Confidence.definite : Confidence.possible, span))
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

"""Accesses of all units of one method: writes, reads, blind writes, blind reads, result aliases."""
const Collected = Tuple{Vector{Access}, Vector{Access}, Vector{BlindAccess}, Vector{BlindAccess}, Vector{Place.Type}}

"""
`effects` stage facts of `package` from inference `units`, and blind spots: summary per package method over its units
(`effects.md`, Units and Facts). Crash `journal` records native inference of instances outside units.
"""
function effects_facts(package::PackageFacts, units::Units, journal::Union{Nothing, Journal})::Tuple{EffectsFacts, Vector{BlindSpot}}
    run = start_run(journal)
    typed_of = IdDict{Core.MethodInstance, TypedCode}()
    for typed in units.typed
        instance = typed.frame.linfo
        haskey(typed_of, instance) && continue
        typed_of[instance] = typed
        run.bodies[instance] = frame_body(run, typed.frame)
    end
    roots = Variant[(typed.frame.linfo, Pair{Int, Any}[]) for typed in units.typed if typed_of[typed.frame.linfo] === typed]
    solve!(run, roots)
    spots = BlindSpot[]
    found = IdDict{Method, Collected}()
    for root in roots
        typed = typed_of[first(root)]
        # Unit that always throws on stand-ins shows no behavior of declared signature.
        typed.result === Union{} && (push!(spots, BlindSpot("always throws on stand-ins", typed.site.span)); continue)
        summary, code = run.summaries[root], run.codes[root]
        span_of(cause::Int)::Span = cause_span(typed, code, cause)
        writes, reads, blind_writes, blind_reads, aliases = get!(() -> (Access[], Access[], BlindAccess[], BlindAccess[], Place.Type[]), found, typed.site.method)
        unit_writes, unit_blind_writes = unit_accesses(summary.writes, span_of)
        unit_reads, unit_blind_reads = unit_accesses(summary.reads, span_of)
        append!(writes, unit_writes)
        append!(reads, unit_reads)
        append!(blind_writes, unit_blind_writes)
        append!(blind_reads, unit_blind_reads)
        append!(aliases, result_aliases(summary))
    end
    methods = MethodEffects[]
    for site in package.methods
        haskey(found, site.method) || continue
        writes, reads, blind_writes, blind_reads, aliases = found[site.method]
        effects = MethodEffects(site, worst(writes), worst(reads), blind_order(blind_writes), blind_order(blind_reads), sort!(unique!(aliases); by = repr), !(site.method in units.incomplete))
        push!(methods, effects)
        append!(spots, (access.spot for access in [effects.blind_writes; effects.blind_reads]))
    end
    return EffectsFacts(methods), unique!(spots)
end
