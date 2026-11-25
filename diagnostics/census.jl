# Sources of `possible` writes: each write of package method traced through callee summaries to statement that starts it.
# Usage: julia --project=<work>/env-<Name> diagnostics/census.jl <Name> <work>/<Name> <methods.tsv>
# `benchmark/effects.jl` makes <work>. Output: methods by source group and label; TSV holds label set of each method.

using Corset: Corset
using Corset.Effects.Summaries: Summaries, CC, Level, Outcome, Operand, Variant, level_of, root_summary!, solve!, source_provenance, sources_of, start_run, unit_body!
using Corset.Effects.Summaries: @match
using Corset.Signatures: Provenance

"""Labels of one method: sources of its `possible` writes."""
const Labels = Set{String}

"""Value of `operand`; `nothing` for spread part or rest."""
operand_value(operand::Operand.Type)::Any = @match operand begin
    Operand.Value(value) => value
    _ => nothing
end

"""Name of constant function that `statement` calls, through `_apply_iterate`; `?` when unknown."""
function statement_callee(ir::CC.IRCode, statement::Any)::String
    statement isa Expr && statement.head in (:call, :invoke) || return "?"
    head = Summaries.constant(ir, statement.args[statement.head === :invoke ? 2 : 1])
    isnothing(head) && return "?"
    f = something(head)
    f === Core._apply_iterate && length(statement.args) >= 3 && return "splat " * statement_callee(ir, Expr(:call, statement.args[3]))
    return f isa Function ? string(nameof(f)) : string(typeof(f))
end

"""Where statement of `variant` lies: `package`, or `library[<method name>]`."""
function site_of(variant::Variant, package::Set{Module})::String
    method = first(variant).def::Method
    return method.module in package ? "package" : "library[$(method.name)]"
end

"""Label of open call with `operands` at `statement`: unknown foreign call, splat, wide dispatch, or open callee."""
function open_label(ir::CC.IRCode, statement::Any, operands::Vector{Operand.Type}, site::String)::String
    statement isa Expr && statement.head === :foreigncall && return "foreign-unknown:$(statement.args[1])"
    callee = statement_callee(ir, statement)
    startswith(callee, "splat ") && return "splat-unknown-length:$site:$(callee[7:end])"
    value = isempty(operands) ? nothing : operand_value(first(operands))
    isnothing(value) && return "callee-spread-part:$site"
    constant = Summaries.constant(ir, value)
    if !isnothing(constant)
        f = something(constant)
        return "wide-dispatch-$site:" * (f isa Function ? string(parentmodule(f), ".", nameof(f)) : string("callable ", typeof(f)))
    end
    value isa Core.Argument && return "callee-parameter:$site"
    value isa Core.SSAValue || return "callee-other:$site:$(typeof(value))"
    definition = ir.stmts[value.id][:stmt]
    statement_callee(ir, definition) in ("getfield", "getproperty") && return "callee-field:$site"
    type = Summaries.value_type(ir, value)
    return "callee-result:$site:$(type isa DataType ? nameof(type) : typeof(type))"
end

"""
Add to `found` labels of statements that start `code` doubt of statement `cause` of `variant`. Dispatch follows `code`
writes of callees; builtin, intrinsic, foreign call and kept contract follow statements that made their operands.
"""
function trace!(found::Labels, run::Summaries.Run, variant::Variant, cause::Int, package::Set{Module}, seen::Set{Tuple{Variant, Int}})::Nothing
    (variant, cause) in seen && return nothing
    push!(seen, (variant, cause))
    haskey(run.codes, variant) || (push!(found, "no-code"); return nothing)
    code = run.codes[variant]
    cause in eachindex(code.outcomes) || (push!(found, "cause-outside-code"); return nothing)
    outcome, site = code.outcomes[cause], site_of(variant, package)
    isnothing(outcome) && (push!(found, "non-call-statement:$site"); return nothing)
    statement = code.ir.stmts[cause][:stmt]
    @match something(outcome) begin
        Outcome.Dispatch(_, _) => trace_callees!(found, run, code.callees[cause], package, seen)
        Outcome.Contract(_, operands, breached) => isempty(breached) ? trace_operands!(found, run, variant, code, operands, package, seen, site) : push!(found, "contract-breach:$site")
        Outcome.Builtin(_, operands) => trace_operands!(found, run, variant, code, operands, package, seen, site)
        Outcome.Intrinsic(_, operands) => trace_operands!(found, run, variant, code, operands, package, seen, site)
        Outcome.Foreign(_, operands) => trace_operands!(found, run, variant, code, operands, package, seen, site)
        Outcome.Dead() => push!(found, "dead")
        Outcome.Unresolved(_) => push!(found, "unresolved-spread:$site:$(statement_callee(code.ir, statement))")
        Outcome.Open(operands) => push!(found, open_label(code.ir, statement, operands, site))
    end
    return nothing
end

"""Trace `code` writes of each solved callee in `callees`."""
function trace_callees!(found::Labels, run::Summaries.Run, callees::Vector{Variant}, package::Set{Module}, seen::Set{Tuple{Variant, Int}})::Nothing
    for callee in callees
        haskey(run.summaries, callee) || continue
        for effect in values(run.summaries[callee].writes)
            level_of(effect.doubt) == Level.code && trace!(found, run, callee, effect.cause, package, seen)
        end
    end
    return nothing
end

"""Trace call statements that made `operands`; label `doubted-target-no-call` when none did."""
function trace_operands!(found::Labels, run::Summaries.Run, variant::Variant, code::Summaries.Code, operands::Vector{Operand.Type}, package::Set{Module}, seen::Set{Tuple{Variant, Int}}, site::String)::Nothing
    sources = Int[value.id for value in operand_value.(operands) if value isa Core.SSAValue && !isnothing(code.outcomes[value.id])]
    isempty(sources) && (push!(found, "doubted-target-no-call:$site"); return nothing)
    foreach(index -> trace!(found, run, variant, index, package, seen), sources)
    return nothing
end

"""Group of `label`: text before first colon, without method name of library site."""
label_group(label::String)::String = replace(first(split(label, ':')), r"\[.*\]" => "")

"""Count of each key over `keys`, most first."""
function tally(keys::Vector{String})::Vector{Pair{String, Int}}
    counts = Dict{String, Int}()
    foreach(key -> counts[key] = get(counts, key, 0) + 1, keys)
    return sort!(collect(counts); by = pair -> (-last(pair), first(pair)))
end

"""Labels per package method with `possible` write; run solves every unit as `Summaries.cached_effects` does."""
function census(name::String, root::String)::IdDict{Method, Labels}
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
    foreach(((instance, _),) -> run.bodies[instance] = unit_body!(run, typed_of[instance].frame, run.cuts[instance]), roots)
    solve!(run, roots)
    package, labels = Set(loaded.facts.modules), IdDict{Method, Labels}()
    for root_variant in roots
        typed = typed_of[first(root_variant)]
        typed.result === Union{} && continue
        for effect in values(root_summary!(run, root_variant).writes)
            level_of(effect.doubt) == Level.code || continue
            source_provenance(sources_of(effect.doubt), typed.provenance) == Provenance.code || continue
            trace!(get!(Labels, labels, typed.site.method), run, root_variant, effect.cause, package, Set{Tuple{Variant, Int}}())
        end
    end
    return labels
end

"""Print groups and top labels of `labels`; write label set of each method to `table`."""
function report(labels::IdDict{Method, Labels}, table::String)::Nothing
    open(table, "w") do io
        for (method, found) in labels
            println(io, method.module, ".", method.name, " ", method.file, ":", method.line, "\t", join(sort!(collect(found)), "\x1f"))
        end
    end
    groups = [unique(label_group.(collect(found))) for found in values(labels)]
    sole = Dict(tally(String[only(kinds) for kinds in groups if length(kinds) == 1]))
    println("methods_with_possible=", length(labels))
    println("by group (methods; sole: methods with no other group):")
    for (group, count) in tally(reduce(vcat, groups; init = String[]))
        println("  ", rpad(group, 34), lpad(count, 5), "  sole=", get(sole, group, 0))
    end
    println("by label (methods), top 45:")
    for (label, count) in first(tally(reduce(vcat, collect.(values(labels)); init = String[])), 45)
        println("  ", rpad(label, 80), count)
    end
    return nothing
end

report(Base.invokelatest(census, ARGS[1], ARGS[2]), ARGS[3])
