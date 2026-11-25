# Definite writes that Base contract or join starts: sample for hand audit (`phase5.md`, row 5 gate).
# Usage: julia --project=<work>/env-<Name> diagnostics/audit.jl <Name> <work>/<Name> <audit.tsv>
# `benchmark/effects.jl` makes <work>. Output: one row per (method, place, origin), with chain and cause source text.
# Trace follows every definite write of static callee, so origin of one place can over-approximate.

using Corset: Corset
using Corset.Effects.Summaries: Summaries, Level, Outcome, Variant, cause_span, level_of, root_summary, solve!, start_run, unit_body
using Corset.Effects.Summaries: @match

"""Origin of definite write: `contract` or `join`, callee name, and chain of callee methods from root to it."""
const Origin = @NamedTuple{kind::String, callee::String, chain::Vector{String}}

"""Name of method that `variant` runs: module, name, file and line."""
function method_name(variant::Variant)::String
    method = first(variant).def::Method
    return "$(method.module).$(method.name) $(basename(string(method.file))):$(method.line)"
end

"""Name of function that statement `cause` of `code` calls; `?` when unknown."""
function called(code::Summaries.Code, cause::Int)::String
    statement = code.ir.stmts[cause][:stmt]
    statement isa Expr && statement.head in (:call, :invoke) || return "?"
    head = Summaries.constant(code.ir, statement.args[statement.head === :invoke ? 2 : 1])
    isnothing(head) && return "?"
    f = something(head)
    return f isa Function ? string(parentmodule(f), ".", nameof(f)) : string(typeof(f))
end

"""
Add to `found` origins of definite write at statement `cause` of `variant`. Static call follows definite writes of its
callee; contract and join end trace; builtin, intrinsic and foreign call write in code itself.
"""
function origins!(found::Vector{Origin}, run::Summaries.Run, variant::Variant, cause::Int, chain::Vector{String}, seen::Set{Tuple{Variant, Int}})::Nothing
    (variant, cause) in seen && return nothing
    push!(seen, (variant, cause))
    haskey(run.codes, variant) || return nothing
    code = run.codes[variant]
    cause in eachindex(code.outcomes) || return nothing
    outcome = code.outcomes[cause]
    isnothing(outcome) && return nothing
    @match something(outcome) begin
        Outcome.Contract(_, _, _) => push!(found, (kind = "contract", callee = called(code, cause), chain))
        Outcome.Dispatch(_, _) => begin
            callees = code.callees[cause]
            if length(callees) > 1
                push!(found, (kind = "join", callee = join(method_name.(callees), " | "), chain))
            else
                for callee in callees
                    haskey(run.summaries, callee) || continue
                    for effect in values(run.summaries[callee].writes)
                        level_of(effect.doubt) == Level.none && origins!(found, run, callee, effect.cause, [chain; method_name(callee)], seen)
                    end
                end
            end
        end
        _ => nothing
    end
    return nothing
end

"""Source text of `span`, on one line, at most 160 characters."""
function span_text(span::Corset.Facts.Span)::String
    isfile(span.file) || return "?"
    bytes = read(span.file)
    text = String(bytes[span.first_byte:min(span.last_byte, length(bytes))])
    return first(replace(text, r"\s+" => " "), 160)
end

"""Line of byte `byte` in `file`."""
line_of(file::String, byte::Int)::Int = isfile(file) ? count(==(UInt8('\n')), read(file)[1:(byte - 1)]) + 1 : 0

"""Rows of definite writes that contract or join starts, over every unit as `Summaries.cached_effects` solves them."""
function audit(name::String, root::String)::Vector{String}
    Base.require(Main, Symbol(name))
    sources = Corset.Discovery.discover(root; environment = nothing)
    loaded = Corset.Package.load(sources.project, sources.files)
    _, _, units, _ = Corset.Inference.infer_package(loaded.facts, sources.files, nothing, nothing)
    run = start_run(nothing, loaded.facts.modules)
    typed_of = IdDict{Core.MethodInstance, Any}()
    for typed in units.typed
        haskey(typed_of, typed.frame.linfo) && continue
        typed_of[typed.frame.linfo] = typed
        run.cuts[typed.frame.linfo] = !isempty(typed.cuts)
    end
    roots = Variant[(typed.frame.linfo, Pair{Int, Any}[]) for typed in units.typed if typed_of[typed.frame.linfo] === typed]
    foreach(((instance, _),) -> run.bodies[instance] = unit_body(run, typed_of[instance].frame, run.cuts[instance]), roots)
    solve!(run, roots)
    rows = String[]
    for root_variant in roots
        typed = typed_of[first(root_variant)]
        (typed.result === Union{} || !haskey(run.codes, root_variant)) && continue
        for ((place, below, kind), effect) in root_summary(run, root_variant).writes
            level_of(effect.doubt) == Level.none || continue
            found = Origin[]
            origins!(found, run, root_variant, effect.cause, String[], Set{Tuple{Variant, Int}}())
            span = cause_span(typed, run.codes[root_variant], effect.cause)
            for origin in unique(found)
                fields = (name, method_name(root_variant), string(first(root_variant).specTypes), repr(place), below, kind, origin.kind, origin.callee, join(origin.chain, " > "), "$(basename(span.file)):$(line_of(span.file, span.first_byte))", span_text(span))
                push!(rows, join(fields, '\t'))
            end
        end
    end
    return unique!(rows)
end

rows = Base.invokelatest(audit, ARGS[1], ARGS[2])
write(ARGS[3], join(rows, '\n'), '\n')
kinds = [split(row, '\t')[7] for row in rows]
println("rows=", length(rows), " contract=", count(==("contract"), kinds), " join=", count(==("join"), kinds))
