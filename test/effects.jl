using Test: @test, @testset, @test_throws, @test_broken
using Corset: Corset
using Corset.Facts: Facts, Callee, methods_callee, callee_methods, Access, Place, Root, Step, Confidence, BlindSpot, Span, Precision, EffectKind, PATH_DEPTH
using Corset.Inference: infer_package, open_journal, records, explicit_any, cuts!, dead_calls
using Corset.StandIns: FunctionStandIn, ArrayStandIn, DenseStandIn, FloatStandIn
using Corset.Signatures: Provenance
using Corset.Effects.Summaries:
    Summaries, MethodVerdict, CallSummary, BlindAccess, UnitVerdict, Library, cached_effects, Doubt, Level, Sources, BLIND, level_of, sources_of, NO_DOUBT, CODE_DOUBT, BLIND_DOUBT, OPAQUE, INHERENT, LAST_PARAMETER, parameter_source, least, Effect, Summary, Node, Nodes, Origin, Targets, Operand, Outcome, Code, Flow, start_run, solve!, dispatch, body!,
    library_body!, journal_key, stronger, most, same, empty_summary, open_summary, referent!, field_step, backing_field, slot_type,
    element_type, constant, value_type, start_flow, statement!, map_node!, CallSite, cause_span, root_of, resolve, operand_type, access!, add!, deep, worst,
    components, foreign_name, foreign_library, FOREIGN_EFFECTS, BLAS_EFFECTS, foreign_effects, blas_library, CallEffects, join_accesses!, JOIN_LIMIT, join_limit, widen, UNSETTLED, Accesses, Edges, Holds, null_pointer, variant_parameters!, Body, type_sources, static_sources, derive!, caller_doubt!, source_provenance,
    Callback, Callees, Variant, root_summary!, deferred, parameter_origin, Shortcut, claims!, reaches_untrusted!, stand_in_cut!, CUT, catches!, cut!,
    special_kind, audited_field, site_kind, field_kind, scheduler_method, step_type, HoldCount, HoldCounts, Unguarded, Resource, Path, PATH_LIMIT, plus, join_hold, widen_holds,
    unsettled, add_path!, RELEASE_PATTERN, ZERO_HOLD, unit_body!, root_calls!, merge_calls, merge_callees, load!, store!, store_backing!,
    beneath, map_nodes!, merges_exactly, exact_path, extend, load_any, keyword_types, over_budget, outside_targets!, unknown, Slot, held_summary,
    after_successors, component_graph
using Supposition: Supposition, Data, @check, @composed
using Moshi.Data: isa_variant
using Random: Random, Xoshiro, AbstractRNG
using LinearAlgebra: LinearAlgebra, UpperTriangular, ldiv!
using Scratch: Scratch
using Serialization: Serialization
using Base.ScopedValues: ScopedValue
include("coverage.jl")

const CASE = joinpath(@__DIR__, "effects", "EffectsCases")

"""
Fixture module, files, package facts, inference units, engine verdicts and blind spots of `EffectsCases`, loaded with
case on load path.
"""
function case_facts()::Tuple{Module, Vector{Facts.SyntaxFile}, Facts.PackageFacts, Corset.Inference.Units, Vector{MethodVerdict}, Vector{BlindSpot}}
    sources = Corset.Discovery.discover(CASE; environment = nothing)
    push!(LOAD_PATH, CASE)
    loaded = try
        Corset.Package.load(sources.project, sources.files)
    finally
        pop!(LOAD_PATH)
    end
    _, _, units, _ = infer_package(loaded.facts, sources.files, nothing, nothing)
    facts, spots = cached_effects(loaded.facts, units, Union{Nothing, UnitVerdict}[], nothing, Library())
    return first(loaded.facts.modules), sources.files, loaded.facts, units, facts, spots
end

const CASES, FILES, PACKAGE, UNITS, FACTS, SPOTS = case_facts()

"""Place at parameter `position` (1 is called function) and `steps`."""
parameter(position::Int, steps::Step.Type...)::Place.Type = Place.At(Root.Parameter(position), Step.Type[steps...])

"""Place of global `name` of `holder`."""
global_place(holder::Module, name::Symbol)::Place.Type = Place.At(Root.Global(GlobalRef(holder, name)), Step.Type[])

"""`code` doubt from open types of parameters at `positions`."""
sourced(positions::Int...)::Doubt = Doubt(Level.code, reduce(|, map(parameter_source, positions)))

"""Effects of fixture method `name` whose argument types are `types`."""
function effects(name::Symbol, types::Type...)::MethodVerdict
    return only(found for found in FACTS if found.site.method.name == name && collect(fieldtypes(found.site.method.sig))[2:end] == collect(types))
end

"""Place, coverage and confidence of each of `accesses`."""
shape(accesses::Vector{Access})::Vector{Tuple{Place.Type, Bool, Confidence.T}} = [(access.place, access.below, access.confidence) for access in accesses]

"""Place, coverage and cause of each blind access of `accesses`."""
blind_shape(accesses::Vector{BlindAccess})::Vector{Tuple{Place.Type, Bool, String}} = [(access.place, access.below, access.spot.cause) for access in accesses]

"""Source line that holds first byte of `span` in fixture files."""
function line_text(span::Span)::String
    file = only(file for file in FILES if file.path == span.file)
    start = something(findprev('\n', file.text, span.first_byte), 0) + 1
    stop = something(findnext('\n', file.text, span.first_byte), ncodeunits(file.text) + 1) - 1
    return file.text[start:stop]
end

@testset "fixture verdicts" begin
    definite, possible = Confidence.definite, Confidence.possible
    box, next, content = Step.Field(:box), Step.Field(:next), Step.Field(:content)
    @test shape(effects(:set_value!, CASES.Box, Int).writes) == [(parameter(2), false, definite)]
    @test line_text(only(effects(:set_value!, CASES.Box, Int).writes).cause) == "set_value!(box::Box, value::Int)::Nothing = (box.value = value; nothing)"
    @test shape(effects(:set_inner!, CASES.Holder, Int).writes) == [(parameter(2, box), false, definite)]
    @test shape(effects(:set_deep!, CASES.Chain, Int).writes) == [(parameter(2, next, box), false, definite)]
    # Path follows declared field types: concrete nesting stays exact.
    deeper = (parameter(2, Step.Field(:chain), next, box), false, definite)
    @test shape(effects(:set_deeper!, CASES.Wrapper, Int).writes) == [deeper] && isempty(effects(:set_deeper!, CASES.Wrapper, Int).blind_writes)
    @test shape(effects(:call_deeper!, CASES.Wrapper).writes) == [deeper]
    # Recursive type collapses path to `deep`; write below it keeps certainty, unless root reaches `IO`.
    @test shape(effects(:relink!, CASES.Link).writes) == [(Place.Deep(Root.Parameter(2)), false, definite)]
    # Exempt kind needs proof: written object type at access, or callee kind. Unproven raw `IO` memory write is memory write.
    @test shape(effects(:relink_io!, CASES.IOLink).writes) == [(Place.Deep(Root.Parameter(2)), false, definite)]
    @test unique(access.kind for access in effects(:rewind_io!, CASES.IOLink).writes) == [EffectKind.io]
    @test shape(effects(:clear_io!, CASES.IOLink).writes) == [(Place.Deep(Root.Parameter(2)), false, definite)]
    @test shape(effects(:fill_first!, Vector{Int}).writes) == [(parameter(2), false, definite)]
    @test shape(effects(:swap_first!, Vector{Int}, Int).writes) == [(parameter(2), false, definite)]
    for (name, types) in ((:first_value, (Vector{Int},)), (:read_box, (CASES.Box,)), (:copy_box, (CASES.Box,)), (:load_pointer, (Vector{Int},)))
        @test isempty(effects(name, types...).writes)
        @test shape(effects(name, types...).reads) == [(parameter(2), false, definite)]
    end
    @test isempty(effects(:add, Int, Int).writes) && isempty(effects(:add, Int, Int).reads)
    @test isempty(effects(:fresh_sum, Int).writes)
    @test shape(effects(:bump!).writes) == [(global_place(CASES, :COUNTER), false, definite)]
    @test shape(effects(:set_total!, Int).writes) == [(global_place(CASES, :total), false, definite)]
    @test shape(effects(:read_total).reads) == [(global_place(CASES, :total), false, definite)]
    @test shape(effects(:read_module).reads) == [(global_place(CASES, :total), false, definite)]
    @test (parameter(2), false, definite) in shape(effects(:push_box!, Vector{CASES.Box}, CASES.Box).writes)
    @test effects(:first_view, Vector{Int}).aliases == [parameter(2)]
    @test shape(effects(:zero_view!, Vector{Int}).writes) == [(parameter(2), false, definite)]
    @test effects(:counter_ref).aliases == [global_place(CASES, :COUNTER)]
    @test shape(effects(:reset_counter!).writes) == [(global_place(CASES, :COUNTER), false, definite)]
    @test effects(:boxes_of, CASES.Box).aliases == [parameter(2)] && isempty(effects(:boxes_of, CASES.Box).writes)
    # Open call result may be unknown object.
    @test Place.At(Root.Elsewhere(), Step.Type[]) in effects(:call_on, Any, CASES.Box).aliases
    for name in (:countdown!, :ping!, :pong!)
        @test shape(effects(name, CASES.Box, Int).writes) == [(parameter(2), false, definite)]
    end
    @test shape(effects(:increment!, CASES.Counter).writes) == [(parameter(2), false, definite)]
    @test shape(effects(:swap_count!, CASES.Counter, Int).writes) == [(parameter(2), false, definite)]
    @test shape(effects(:touch!, CASES.Box).writes) == [(parameter(2), false, definite)]
    @test isempty(effects(:touch!, String).writes)
    @test shape(effects(:poke!, CASES.Loose).writes) == [(parameter(2, content), false, possible)]
    either = Union{Base.RefValue{Int}, Base.RefValue{Float64}}
    # Join: methods that agree keep certainty; methods loaded now decide it, so verdict is closed-world.
    @test shape(effects(:stamp_either!, either).writes) == [(parameter(2), false, definite)] && effects(:stamp_either!, either).closed_world
    @test isempty(effects(:measure_either, either).writes) && effects(:measure_either, either).closed_world
    @test effects(:poke!, CASES.Loose).closed_world && !effects(:set_value!, CASES.Box, Int).closed_world
    @test shape(effects(:copy_into!, Vector{Int}, Vector{Int}).writes) == [(parameter(2), false, definite)]
    # Store keeps old slot content beside new value (no strong update), so sure write through slot reads as `possible`.
    @test_broken (parameter(3, Step.Element()), false, definite) in shape(effects(:copy_boxes!, Vector{CASES.Box}, Vector{CASES.Box}).writes)
    @test_broken (parameter(3), false, definite) in shape(effects(:remember!, IdDict{Int, CASES.Box}, CASES.Box).writes)
    @test shape(effects(:store_pointer!, Vector{Int}).writes) == [(parameter(2), false, definite)]
    # Constant global takes type of its value: nested `Ref` path stays exact.
    nest = (Place.At(Root.Global(GlobalRef(CASES, :NEST)), Step.Type[Step.Field(:x), Step.Field(:x), Step.Field(:x)]), false, definite)
    @test shape(effects(:bump_nest!).writes) == [nest] && shape(effects(:call_nest!).writes) == [nest]
    @test all(found -> found.site.method.name != :fail, FACTS)
    @test BlindSpot("always throws on stand-ins", only(site for site in UNITS.typed if site.site.method.name == :fail).site.span) in SPOTS
    # Merge of two independent callee objects would alias them: write through merged object is blind spot.
    twin = effects(:twin_write!, CASES.Box)
    @test isempty(twin.writes) && blind_shape(twin.blind_writes) == [(parameter(2), false, "alias")]
    @test any(spot -> spot.cause == "alias", SPOTS)
    # Stand-in cuts make method incomplete too ("stand-in cuts" testset).
    @test all(found -> !(found.site.method in UNITS.incomplete) || !found.complete, FACTS)
end

@testset "caller-chosen default RNG" begin
    rng_kinds(accesses::Vector{Access})::Set{Tuple{Place.Type, EffectKind.T}} = Set((access.place, access.kind) for access in accesses if access.kind in (EffectKind.default_rng, EffectKind.rng_argument))
    chosen, default = (parameter(2), EffectKind.default_rng), (Place.At(Root.Elsewhere(), Step.Type[]), EffectKind.default_rng)
    drawers = Dict(name => effects(name, AbstractRNG, AbstractVector) for name in (:draw_from, :draw_both, :draw_each, :draw_captured))
    # Each drawer has unit with `TaskLocalRNG` argument from its `*_default` caller.
    for found in values(drawers)
        @test any(typed -> typed.site.method === found.site.method && fieldtype(typed.signature, 2) === Random.TaskLocalRNG, UNITS.typed)
    end
    # Caller passes `default_rng()`: draw through argument, directly or through closure, moves there; caller reads default RNG.
    for name in (:draw_from, :draw_each), accesses in (drawers[name].writes, drawers[name].reads)
        @test chosen in rng_kinds(accesses) && !(default in rng_kinds(accesses))
    end
    moved = only(access for access in drawers[:draw_from].writes if (access.place, access.kind) == chosen)
    @test moved.confidence == Confidence.definite
    # Moved draw still touches `Task` state for `:notaskstate` claims, yet hides no input.
    @test Corset.Rules.FalseEffects.task_state(moved)
    @test isnothing(Corset.Rules.HiddenInput.input(moved, Module[CASES]))
    drawn(name::Symbol)::Bool = Corset.Rules.HiddenInput.draws_from([drawers[name].writes; drawers[name].reads], 1)
    @test drawn(:draw_each) && !drawn(:draw_both)
    @test all(name -> rng_kinds(effects(name, AbstractVector).writes) == Set([default]), (:draw_default, :draw_both_default, :draw_each_default, :draw_captured_default))
    # Bare `rand()` beside draw from argument keeps default RNG.
    @test default in rng_kinds(drawers[:draw_both].writes)
    # Closure over `default_rng()` keeps default RNG: declared signature unit reads it.
    @test default in rng_kinds(drawers[:draw_captured].writes)
    # Declared `TaskLocalRNG` keeps default RNG: method, not caller, chose it.
    @test rng_kinds(effects(:draw_task, Random.TaskLocalRNG, AbstractVector).writes) == Set([default])
    # Folded constant counts as RNG argument only when it holds `TaskLocalRNG` within depth.
    task_rng = Random.TaskLocalRNG()
    @test Summaries.holds_task_rng((1, (task_rng,)), 3) && !Summaries.holds_task_rng((1, (2,)), 3)
    @test Summaries.holds_task_rng((((task_rng,),),), 3) && !Summaries.holds_task_rng(((((task_rng,),),),), 3)
    @test !Summaries.holds_task_rng((Int, Base), 3)
end

"""Effects of only fixture method `name`."""
named(name::Symbol)::MethodVerdict = only(found for found in FACTS if found.site.method.name == name)

@testset "provenance" begin
    possible, opaque, elsewhere = Confidence.possible, Summaries.OPAQUE_DATA, Place.At(Root.Elsewhere(), Step.Type[])
    # Open dispatch on type Corset chose: blind spot only, on every place call reaches.
    @test isempty(named(:reset_first!).writes)
    @test blind_shape(named(:reset_first!).blind_writes) == [(parameter(2, Step.Field(:data), Step.Element()), true, opaque)]
    @test isempty(named(:apply_to!).writes) && blind_shape(named(:apply_to!).blind_writes) == [(parameter(3), true, opaque)]
    # Callee open dispatch on its parameter: caller argument decides.
    for name in (:emit!, :emit_through!)
        @test isempty(named(name).writes)
        @test blind_shape(named(name).blind_writes) == [(parameter(2), true, opaque), (parameter(3), true, opaque)]
    end
    # Open call result keeps source of its open types: open call on it is blind too.
    @test isempty(named(:emit_peer!).writes) && (elsewhere, true, opaque) in blind_shape(named(:emit_peer!).blind_writes)
    # Explicit `Any` opts out, also with default value: no access, no blind spot.
    defaulted = only(found for found in FACTS if found.site.method.name == :reset_default! && found.site.method.nargs == 2)
    for found in (named(:reset_any!), named(:reset_slot!), named(:call_on), defaulted)
        @test isempty(found.writes) && isempty(found.blind_writes)
    end
    @test explicit_any(named(:call_on).site, :f) && !explicit_any(named(:call_on).site, :box)
    # Unit call reaches keeps caller types: `Vector{Any}` from `fill_any!` is code there.
    reached = named(:reset_items!)
    @test !isempty(reached.writes) && all(access -> access.confidence == possible, reached.writes) && isempty(reached.blind_writes)
    # Open type code wrote: `possible`, also beside opaque type.
    @test shape(named(:reset_typed!).writes) == [(parameter(2), true, possible)]
    @test shape(named(:emit_typed!).writes) == [(parameter(2), true, possible), (parameter(3), true, possible)]
    @test any(spot -> spot.cause == opaque, SPOTS)
end

"""Key of memory access to `place` with `below`."""
memory(key::Tuple{Place.Type, Bool})::Tuple{Place.Type, Bool, EffectKind.T} = (key..., EffectKind.memory)

"""Doubt per access of `table`; memory access drops kind from key, so plain place keys compare."""
doubts(table::Dict{Tuple{Place.Type, Bool, EffectKind.T}, Effect})::Dict{Tuple, Doubt} = Dict((kind == EffectKind.memory ? (place, below) : (place, below, kind)) => effect.doubt for ((place, below, kind), effect) in table)

"""Summary of fixture method `f` on argument `types`, solved as package code, before root resolves its callback records."""
function raw_summary(f::Any, types::Type...)::Summary
    run = start_run(nothing, Module[CASES])
    root = (only(something(dispatch(Any[typeof(f), types...], run.world, 1))), Pair{Int, Any}[])
    solve!(run, [root])
    return held_summary(run.slots, root)
end

@testset "callback records" begin
    definite, box = Confidence.definite, Step.Field(:box)
    # Callable from caller writes where caller made it: no path through reducers, so no blind spot.
    for name in (:fill_pair!, :push_pair!, :set_pair!, :count_down!)
        @test shape(named(name).writes) == [(parameter(2), false, definite)] && isempty(named(name).blind_writes)
    end
    # Root unit keeps record for caller in its summary, then resolves it for its own verdict.
    raw = raw_summary(CASES.call_setter!, CASES.Setter, Int)
    @test only(raw.callbacks).parameters[1] == Nodes(Node.Placed(parameter(2)) => NO_DOUBT) && !haskey(raw.writes, (parameter(2, box), false))
    @test shape(named(:call_setter!).writes) == [(parameter(2, box), false, definite)]
    # Callable that caller passes makes that write, so access carries callback mark. Own closure write carries none.
    @test only(named(:call_setter!).writes).callback && !any(access -> access.callback, named(:fill_pair!).writes)
    @test isempty(raw_summary(CASES.set_pair!, CASES.Box).callbacks)
    # Units split `Union` stand-ins: `Relay` unit resolves record of `Relay` call, then record of `Setter` call inside it.
    setter = Step.Field(:setter)
    @test shape(named(:act_either!).writes) == [(parameter(2, box), false, definite), (parameter(2, setter, box), false, definite)]
    # Join resolves records of its members: each member writes its own place, and type of parameter 2 picks member.
    either = raw_summary(CASES.act_either!, Union{CASES.Setter, CASES.Relay}, Int)
    @test doubts(either.writes) == Dict((parameter(2, box), false) => sourced(2), (parameter(2, setter, box), false) => sourced(2))
    @test isempty(either.callbacks)
    # Cycle member that resolves record of other member reads its summary, so it reruns when that summary changes.
    @test shape(named(:restart!).writes) == [(parameter(2), false, definite), (parameter(3), false, definite)]
    # Record of earlier round goes when callable grows to fresh object: call resolves here.
    @test isempty(raw_summary(CASES.pick_setter!, CASES.Setter, Int).callbacks)
    # Loop joins caller setter of round 1 with fresh one of round 2, so sure write reads as `possible`.
    @test_broken shape(named(:pick_setter!).writes) == [(parameter(2, box), false, definite)]
    # Record waits for caller only when callable holds object below caller parameter, beside no fresh object.
    held, fresh = Targets(Origin.Caller(parameter(2)) => NO_DOUBT), Targets(Origin.Allocation(1) => NO_DOUBT)
    @test deferred([held, Targets()]) && !deferred([held, fresh]) && !deferred([fresh])
    @test !deferred([Targets(Origin.Caller(Place.Deep(Root.Parameter(2))) => BLIND_DOUBT)])
    @test !deferred([Targets(Origin.Caller(global_place(CASES, :COUNTER)) => NO_DOUBT)]) && !deferred([Targets(Origin.Unknown() => CODE_DOUBT)])
    @test parameter_origin(Origin.Caller(parameter(3, box))) && !parameter_origin(Origin.Unknown())
    # Root without records keeps summary of solve.
    run = start_run(nothing, Module[])
    root = (only(something(dispatch(Any[typeof(CASES.set_value!), CASES.Box, Int], run.world, 1))), Pair{Int, Any}[])
    solve!(run, [root])
    @test root_summary!(run, root) === held_summary(run.slots, root)
end

"""Method never called: it has no inferred code."""
never_called(x::Int)::Int = x + 2

"""Method whose source test removes."""
sourceless(x::Int)::Int = x + 3

@testset "compiler effects" begin
    definite = Confidence.definite
    run = start_run(nothing, Module[CASES])
    instance_of(f::Any, types::Type...)::Core.MethodInstance = only(something(dispatch(Any[typeof(f), types...], run.world, 1)))
    # Compiler proves `+` empty: shortcut, no code. Each other instance fails one condition, so engine analyzes it.
    # Base instances: coverage counters are effects, so instrumented fixture code never takes shortcut.
    @test body!(run, instance_of(+, Int, Int)) isa Shortcut
    scope = Base.ScopedValues.ScopedValue{Int}
    for (f, types) in ((setindex!, (Base.RefValue{Int}, Int)), (getindex, (Base.RefValue{Int},)), (getindex, (scope,)), (identity, (Vector{Int},)), (CASES.call_claim_bump!, ()), (CASES.call_generated, (Int,)))
        @test body!(run, instance_of(f, types...)) isa Body
    end
    root = (instance_of(+, Int, Int), Pair{Int, Any}[])
    solve!(run, [root])
    @test same(root_summary!(run, root), empty_summary()) && !haskey(run.codes, root)
    # Unit verdict keeps no read of constant `Memory` length, which own analysis reads. Fixture coverage turns shortcut off.
    @test isempty(named(:memory_length).reads) == !instrumented(CASE)
    own = start_run(nothing, Module[CASES])
    length_root = (instance_of(CASES.memory_length, Memory{Int}), Pair{Int, Any}[])
    own.bodies[first(length_root)] = Summaries.frame_body!(own, Core.Compiler.typeinf_frame(own.interpreter, first(length_root), false), false, false, false)
    solve!(own, [length_root])
    @test collect(keys(held_summary(own.slots, length_root).reads)) == [memory((parameter(2), false))]
    # Claim outside Base turns shortcut off: own analysis finds write that false claim hides.
    @test shape(named(:call_claim_bump!).writes) == shape(named(:claim_bump!).writes) == [(global_place(CASES, :COUNTER), false, definite)]
    # Compaction keeps call whose callee claims effects, and statement under block claim.
    for name in (:claim_set!, :drop_claim_set!, :block_claim!, :drop_block_claim!)
        @test shape(named(name).writes) == [(parameter(2), false, definite)]
    end
    @test claims!(run, only(methods(CASES.claim_bump!))) && claims!(run, only(methods(CASES.block_claim!))) && claims!(run, only(methods(CASES.generated_next)))
    # Base claims stay trusted.
    @test !claims!(run, only(methods(CASES.set_value!))) && !claims!(run, which(codeunit, (String, Int)))
    method = only(methods(sourceless))
    method.source = nothing
    @test claims!(run, method)
    # Callee without inferred code counts as untrusted. Search that finds none marks instances it visited; other edges skip.
    @test reaches_untrusted!(run, Any[Base.method_instance(never_called, (Int,))])
    plus = Base.method_instance(+, (Int, Int))
    @test !reaches_untrusted!(run, Any[1, Int, plus]) && plus in run.trusted && !reaches_untrusted!(run, Core.svec(plus))
end

"""Library helper outside Base whose type test stand-in decides."""
reset_if_vector!(values) = (values isa Vector && (values[1] = 0); nothing)

"""Library helper outside Base whose type test is false on model types too."""
skip_if_text(values) = (values isa AbstractString && identity(values); nothing)

"""Generated library helper: stand-in code calls `pointer`, model code is shorter."""
@generated generated_library_poke(values) = values <: Vector ? :(nothing) : :(identity(values); pointer(values); nothing)

"""Generated method without code on array stand-in."""
@generated stand_in_broken(x) = x <: ArrayStandIn ? error("no code") : :(x)

"""Unit of fixture method `name`, first in inference order."""
unit(name::Symbol)::Corset.Inference.TypedCode = first(typed for typed in UNITS.typed if typed.site.method.name == name)

"""Blind spot of fixture method `name` with cause `CUT`, if any."""
cut_spots(name::Symbol)::Vector{BlindSpot} = [spot for spot in SPOTS if spot.cause == CUT && spot.span.file == named(name).site.span.file && line_text(spot.span) == line_text(named(name).site.span)]

@testset "stand-in cuts" begin
    definite = Confidence.definite
    # Stand-in decides type test: write is dead on stand-ins only. Verdict none goes to coverage line.
    @test !isempty(unit(:maybe_bump!).cuts) && isempty(named(:maybe_bump!).writes) && !named(:maybe_bump!).complete
    # Blind spot points at cut statement; caller spot points at call that reaches cut.
    @test only(cut_spots(:maybe_bump!)).span != named(:maybe_bump!).site.span
    # Caller inherits cut through callee summary, though compiler proves caller empty on stand-ins.
    @test isempty(unit(:call_maybe_bump!).cuts) && !named(:call_maybe_bump!).complete && length(cut_spots(:call_maybe_bump!)) == 1
    # Write keeps certainty with cut; verdict is not none, so no blind spot. Compaction keeps empty call to cut unit.
    @test shape(named(:set_maybe_bump!).writes) == [(parameter(2), false, definite)] && !named(:set_maybe_bump!).complete
    @test isempty(cut_spots(:set_maybe_bump!))
    # Branch dead on declared signature too: no cut. Type test alone makes method incomplete.
    @test isempty(unit(:integer_bump!).cuts) && isempty(cut_spots(:integer_bump!))
    # Call that fails on stand-in only is cut; dead return conversion is dead on declared signature too.
    zero = unit(:maybe_zero!)
    @test !isempty(zero.cuts) && all(index -> zero.code.ssavaluetypes[index] === Union{}, zero.cuts) && !isempty(dead_calls(zero.code))
    @test !named(:maybe_zero!).complete && length(cut_spots(:maybe_zero!)) == 1
    # Open stand-in element decides no element-type call (`oneunit(eltype(values))`): loop write stays, no cut.
    @test unit(:fill_units!).signature == Tuple{typeof(CASES.fill_units!), ArrayStandIn{<:Any, 1}} && isempty(unit(:fill_units!).cuts)
    @test shape(named(:fill_units!).writes) == [(parameter(2, Step.Field(:data)), false, definite)] && named(:fill_units!).complete
    # Throw helper fails on every signature, and call that fails on model types too is fact: no cut.
    @test isempty(unit(:check_nonempty).cuts) && isempty(cut_spots(:check_nonempty))
    converted = unit(:maybe_convert)
    @test isempty(converted.cuts) && any(index -> converted.code.ssavaluetypes[index] === Union{}, eachindex(converted.code.code))
    # Stand-in dispatches to throwing package method, model type to writing one: no spot from failure check, cut stays.
    @test !isempty(unit(:maybe_fill!).cuts) && !named(:maybe_fill!).complete && length(cut_spots(:maybe_fill!)) == 1
    # Generated code differs per signature, so no statement lookup crosses signatures.
    @test !isempty(unit(:fallback_bump!).cuts) && !isempty(unit(:generated_poke).cuts)
    # Generator runs on declared signature too, with other code there: generated method reads no declared code.
    @test unit(:generated_shift!).cuts == dead_calls(unit(:generated_shift!).code) && !isempty(unit(:generated_shift!).cuts)
    # Library instance cut: caller is uncaught failure, or caught one that leaves helper `nothrow`.
    for name in (:poke_some!, :poke_quietly!)
        @test isempty(unit(name).cuts) && !named(name).complete && only(cut_spots(name)).span != named(name).site.span
    end
    # Declared signature without code: every dead call counts.
    generated = unit(:generated_bump!)
    @test generated.cuts == dead_calls(generated.code) && !isempty(generated.cuts)
    # Stand-in signature equal to declared signature: no second inference.
    method = only(methods(CASES.maybe_bump!))
    @test cuts!(IdDict{Method, Union{Nothing, Core.CodeInfo}}(), method, method.sig, unit(:maybe_bump!).code, Int[]) == Int[]
    # Library call fails on stand-in only: instance keeps own analysis, and its summary carries cut.
    run = start_run(nothing, Module[CASES])
    instance_of(f::Any, types::Type...)::Core.MethodInstance = only(something(dispatch(Any[typeof(f), types...], run.world, 1)))
    frame_of(instance::Core.MethodInstance)::Core.Compiler.InferenceState = Core.Compiler.typeinf_frame(run.interpreter, instance, false)
    stand_in = instance_of(pointer, ArrayStandIn{Int, 1})
    @test stand_in_cut!(run, frame_of(stand_in)) && (body!(run, stand_in)::Body).cut
    root = (stand_in, Pair{Int, Any}[])
    solve!(run, [root])
    @test held_summary(run.slots, root).cut
    # No stand-in, throw helper, or call that fails on model types too: no cut.
    @test !stand_in_cut!(run, frame_of(instance_of(pointer, Vector{Int})))
    @test !stand_in_cut!(run, frame_of(instance_of(Base.throw_boundserror, ArrayStandIn{Int, 1}, Tuple{Int}))) && first(run.helpers[throw])
    @test !stand_in_cut!(run, frame_of(instance_of(size, ArrayStandIn{Int, 1})))
    @test !stand_in_cut!(run, frame_of(instance_of(CASES.refuse, ArrayStandIn{Int, 1}))) && !first(run.helpers[CASES.reject])
    # Type branch outside Base is cut, `nothrow` or not; stand-in method keeps contracts like Base.
    @test stand_in_cut!(run, frame_of(instance_of(reset_if_vector!, ArrayStandIn{Int, 1})))
    @test cut!(run, instance_of(reset_if_vector!, ArrayStandIn{Int, 1}), Core.Compiler.EFFECTS_TOTAL)
    @test !stand_in_cut!(run, frame_of(instance_of(skip_if_text, ArrayStandIn{Int, 1})))
    @test !stand_in_cut!(run, frame_of(instance_of(+, FloatStandIn, FloatStandIn)))
    @test stand_in_cut!(run, frame_of(instance_of(generated_library_poke, ArrayStandIn{Int, 1})))
    # Cut check runs only on stand-in instance that can fail; instance without code counts as cut.
    total, throwing = Core.Compiler.EFFECTS_TOTAL, Core.Compiler.EFFECTS_THROWS
    vector_pointer = instance_of(pointer, Vector{Int})
    @test !cut!(run, vector_pointer, throwing) && !haskey(run.cuts, vector_pointer) && !cut!(run, instance_of(size, ArrayStandIn{Int, 1}), total)
    @test cut!(run, instance_of(CASES.poke_caught_at!, ArrayStandIn{Int, 1}, Int), total)
    # Base method gets check when it can fail (`pointer` on stand-in only), or when `nothrow` with `try` (`isassigned`).
    @test cut!(run, instance_of(pointer, ArrayStandIn{Float64, 1}), throwing)
    assigned = instance_of(isassigned, ArrayStandIn{Int, 1}, Int)
    @test !haskey(run.cuts, assigned) && (cut!(run, assigned, total); haskey(run.cuts, assigned))
    broken = instance_of(stand_in_broken, ArrayStandIn{Int, 1})
    @test cut!(run, broken, total) && run.cuts[broken]
    # Cut check keeps frame for body, which releases it; body matches one from fresh inference. Solve drops rest.
    poked = instance_of(CASES.poke_caught_at!, ArrayStandIn{Int, 1}, Int)
    @test haskey(run.frames, poked) && body!(run, poked) isa Body && !haskey(run.frames, poked)
    fresh = body!(start_run(nothing, Module[]), poked)
    @test (fresh.lines, fresh.used, fresh.cut) == (run.bodies[poked].lines, run.bodies[poked].used, run.bodies[poked].cut)
    @test !isempty(run.frames) && (solve!(run, Variant[]); isempty(run.frames))
    @test catches!(run, only(methods(CASES.poke_caught_at!))) && catches!(run, only(methods(stand_in_broken)))
    @test !catches!(run, only(methods(CASES.poke_at!)))
end

@testset "engine stage" begin
    run = Corset.Effects.effects_facts(PACKAGE, UNITS, nothing, Library())
    @test [found.site.method for found in run.facts.methods] == [found.site.method for found in FACTS] && length(run.verdicts) == length(UNITS.typed)
    @test issubset(SPOTS, run.spots)
    mktempdir(@__DIR__) do directory
        journal = open_journal(directory)
        journaled = try
            Corset.Effects.effects_facts(PACKAGE, UNITS, journal, Library())
        finally
            close(journal.io)
        end
        @test length(journaled.facts.methods) == length(FACTS)
        @test any(record -> startswith(record.key, "effects\n") && !record.finished, records(directory))
    end
end

"""Summary of method `f` on argument `types`, solved with every instance it reaches."""
function summary_of(f::Any, types::Type...)::Summary
    run = start_run(nothing, Module[])
    root = (only(something(dispatch(Any[typeof(f), types...], run.world, 1))), Pair{Int, Any}[])
    solve!(run, [root])
    return root_summary!(run, root)
end

"""Unknown-slot contents of only exported node of `summary`, which must be fresh; coverage shifts its statement index."""
function fresh_spread(summary::Summary)::Nodes
    holder, nodes = only(summary.spread)
    @test isa_variant(holder, Node.Fresh)
    return nodes
end

"""Place at parameter `position` with no steps, as summary keys hold it."""
top(position::Int)::Tuple{Place.Type, Bool} = (parameter(position), false)

const ANY_REF = Ref{Any}(nothing)
const BYTES = UInt8[1, 2]
const HOLDER = Ref([1])
const NESTED = CASES.Wrapper(CASES.Chain(CASES.Holder(CASES.Box(1))))
const NESTED_TUPLE = foldl((inner, _) -> (inner,), 1:(PATH_DEPTH + 1); init = 1)

"""Node whose `next` field holds its own type."""
mutable struct Loop
    next::Loop
    Loop() = (loop = new(); loop.next = loop; loop)
end

const LOOP = Loop()
global slot::Vector{Int} = [1]
global tally::Int = 0
global loose::Any = nothing

swap_field!(cell::Base.RefValue{Vector{Int}}, values::Vector{Int}) = Core.swapfield!(cell, :x, values)
modify_field!(cell::Base.RefValue{Int}) = Core.modifyfield!(cell, :x, +, 1)
modify_closure!(cell::Base.RefValue{Vector{Int}}, values::Vector{Int}) = Core.modifyfield!(cell, :x, (old, new) -> (push!(old, 1); new), values)
replace_field!(cell::Base.RefValue{Vector{Int}}, values::Vector{Int}) = Core.replacefield!(cell, :x, values, values)
once_field!(cell::Base.RefValue{Vector{Int}}, values::Vector{Int}) = Core.setfieldonce!(cell, :x, values)
named_field!(cell::Base.RefValue{Vector{Int}}, name::Symbol, values::Vector{Int}) = (Core.setfield!(cell, name, values); getfield(cell, name))
rebind!(values::Vector{Int}) = (global slot = values; slot[1] = 2; nothing)
swap_global!(values::Vector{Int}) = Core.swapglobal!(@__MODULE__, :slot, values)
modify_global!() = Core.modifyglobal!(@__MODULE__, :tally, +, 1)
replace_global!(values::Vector{Int}) = Core.replaceglobal!(@__MODULE__, :slot, values, values)
once_global!(values::Vector{Int}) = Core.setglobalonce!(@__MODULE__, :loose, values)
set_named!(holder::Module, name::Symbol, values::Vector{Int}) = Core.setglobal!(holder, name, values)
get_named(holder::Module, name::Symbol) = Core.getglobal(holder, name)
get_slot() = Core.getglobal(@__MODULE__, :slot)
read_holder() = HOLDER[]

element(memory::Memory{Vector{Int}}) = Core.memoryrefnew(Core.memoryrefnew(memory), 1, false)
memory_get(memory::Memory{Vector{Int}}) = Core.memoryrefget(element(memory), :not_atomic, false)
memory_once!(memory::Memory{Vector{Int}}, values::Vector{Int}) = Core.memoryrefsetonce!(element(memory), values, :not_atomic, :not_atomic, false)
memory_swap!(memory::Memory{Vector{Int}}, values::Vector{Int}) = Core.memoryrefswap!(element(memory), values, :not_atomic, false)
memory_modify!(memory::Memory{Vector{Int}}, values::Vector{Int}) = Core.memoryrefmodify!(element(memory), (old, new) -> new, values, :not_atomic, false)
memory_replace!(memory::Memory{Vector{Int}}, values::Vector{Int}) = Core.memoryrefreplace!(element(memory), values, values, :not_atomic, :not_atomic, false)
memory_assigned(memory::Memory{Vector{Int}}) = Core.memoryref_isassigned(element(memory), :not_atomic, false)
fresh_memory() = Core.memorynew(Memory{Vector{Int}}, 2)

wrapped(values::Vector{Int}) = Core.svec(values)
unwrapped(values::Vector{Int}) = Core._svec_ref(Core.svec(values), 1)
barrier(values::Vector{Int}) = Core.compilerbarrier(:type, values)
either(flag::Bool, first::Vector{Int}, second::Vector{Int}) = Core.ifelse(flag, first, second)
scope() = Core.current_scope()
asserted(values::Any) = Core.typeassert(values, Vector{Int})
define(type::DataType) = Core._setsuper!(type, Any)

pointer_set!(pointer::Ptr{Int}) = Core.Intrinsics.atomic_pointerset(pointer, 1, :sequentially_consistent)
pointer_swap!(pointer::Ptr{Int}) = Core.Intrinsics.atomic_pointerswap(pointer, 1, :sequentially_consistent)
pointer_modify!(pointer::Ptr{Int}) = Core.Intrinsics.atomic_pointermodify(pointer, +, 1, :sequentially_consistent)
pointer_replace!(pointer::Ptr{Int}) = Core.Intrinsics.atomic_pointerreplace(pointer, 0, 1, :sequentially_consistent, :sequentially_consistent)
pointer_get(pointer::Ptr{Int}) = Core.Intrinsics.atomic_pointerref(pointer, :sequentially_consistent)
# Wrapper over argument memory: pointer write writes memory; callee write may change wrapper alone (`pop!`).
wrap_store!(m::Memory{Int}) = (unsafe_store!(pointer(Base.wrap(Array, m, 1)), 1); nothing)
wrap_set!(m::Memory{Int}) = (v = Base.wrap(Array, m, 1); v[1] = 1; nothing)
wrap_pop!(m::Memory{Int}) = (pop!(Base.wrap(Array, m, 1)); nothing)
llvm(pointer::Ptr{Int}) = Base.llvmcall("ret ptr %0", Ptr{Int}, Tuple{Ptr{Int}}, pointer)
global_pointer() = cglobal(:jl_n_threads, Cint)
# Library tuple stays nested constant expression in IR.
library_pointer() = cglobal((:jl_n_threads, "libjulia-internal"), Cint)
open_pointer(kind::Type) = cglobal((:jl_n_threads, "libjulia-internal"), kind)
length_of(text::String) = ccall(:strlen, Csize_t, (Cstring,), text)

quoted(values::Vector{Int}) = quote
    $values
end
opaque(values::Vector{Int}) = Base.Experimental.@opaque () -> values
call_quoted(values::Vector{Int}) = quoted(values)
splat(values::Vector{Int}) = NamedTuple{(:a,), Tuple{Vector{Int}}}((values,))
@eval splat_vararg(values::Tuple{Vararg{Vector{Int}}}) = $(Expr(:splatnew, NamedTuple{(:a,), Tuple{Vector{Int}}}, :values))
function caught(values::Vector{Int})
    held = values
    try
        held = [1]
        error()
    catch problem
        return (held, problem)
    end
end
latest!(values::Vector{Int}) = Base.invokelatest(push!, values, 1)
world!(values::Vector{Int}) = Base.invoke_in_world(Base.get_world_counter(), push!, values, 1)
invoked!(values::Vector{Int}) = invoke(push!, Tuple{Vector{Int}, Any}, values, 1)
fill_one!(values::Vector{Int}) = (values[1] = 1; nothing)
invoke_dead(text::String) = invoke(fill_one!, Tuple{Vector{Int}}, text)
invoke_open(values::Vector{Int}, selector::Type) = invoke(fill_one!, selector, values)
"""Selector that is not constant can select any method: `push!` contract covers them all."""
invoke_contract!(values::Vector{Int}, selector::Type) = invoke(push!, selector, values, 1)
# Writes first, so compiler cannot prove call that always throws empty; engine sees unresolved call.
invoke_missing(values::Vector{Int}) = (values[1] = 0; invoke(push!, Tuple{Int}, values))
spread!(values::Vector{Int}, more::Tuple{Int, Int}) = push!(values, more...)
spread_rest!(values::Vector{Int}, more::Tuple{Vararg{Int}}) = push!(values, more...)
nested_spread!(values::Vector{Int}, more::Tuple{Tuple{Int}}) = push!(values, more[1]...)
dynamic!(container::Any) = sort!(container)
nested_apply(values::Vector{Int}, more::Tuple{Tuple{Int}}) = (values[1] = 0; Core._apply_iterate(iterate, Core._apply_iterate, (iterate, push!, values), more))
@eval embedded() = $(Ref([1]))
unknown_field(holder::Module, name::Symbol) = getfield(Core.getglobal(holder, name)::Base.RefValue{Vector{Int}}, :x)
unknown_any(holder::Module, name::Symbol, field::Symbol) = getfield(Core.getglobal(holder, name), field)
first_of_fresh(values::Vector{Int}) = first([values])
any_of_fresh(values::Vector{Int}, field::Symbol) = getfield(getfield([values], :ref), field)
field_global() = getfield(@__MODULE__, :slot)
struct Backed
    memory::Memory{Vector{Int}}
end
first_backed(backed::Backed) = backed.memory[1]
function make_backed(values::Vector{Int})
    memory = Core.memorynew(Memory{Vector{Int}}, 1)
    Core.memoryrefset!(Core.memoryrefnew(memory), values, :not_atomic, false)
    return first_backed(Backed(memory))
end
@generated broken(x) = x <: Int ? error("no code") : :(x)
calls_broken(values::Vector{Int}) = broken(values)
pick!(first::Vector{Int}, second::Vector{Int}, flag::Bool) = ((flag ? first : second)[1] = 0; nothing)
global held::Base.RefValue{Vector{Int}} = Ref([1])
hold!(values::Vector{Int}) = (global held = Ref(values); nothing)
held_write!(values::Vector{Int}) = (hold!(values); held[][1] = 0; nothing)
nest!(cell::Base.RefValue{Base.RefValue{Vector{Int}}}, values::Vector{Int}) = (cell[] = Ref(values); nothing)
nest_write!(cell::Base.RefValue{Base.RefValue{Vector{Int}}}, values::Vector{Int}) = (nest!(cell, values); cell[][][1] = 0; nothing)
open_on!(f::Any, x::Any) = (f(x); nothing)
open_wrapped!(f::Any, values::Vector{Int}) = open_on!(f, Ref(values))
open_keywords!(f::Any, x::Any) = (f(x; flag = true); nothing)
open_result(f::Any, values::Vector{Int}) = f(values)
open_result_write!(f::Any, values::Vector{Int}) = ((open_result(f, values)::Vector{Int})[1] = 0; nothing)
open_element!(f::Any, values::Vector{Int}) = (f(values[1]); nothing)
# Callers pass callee arguments in other positions, so caller maps each source to its own parameter.
open_result_swapped(values::Vector{Int}, f::Any) = open_result(f, values)
open_unknown!(f::Any) = (f(nothing)(nothing); nothing)
open_unknown_through!(::Any, f::Any) = open_unknown!(f)
# Step from unknown object keeps chain sources, through constant field and through unknown slot.
open_loaded!(f::Any) = (((f(nothing)::Base.RefValue{Any})[])(nothing); nothing)
open_loaded_any!(f::Any, name::Symbol) = (getfield(f(nothing)::Base.RefValue{Any}, name)(nothing); nothing)
# Type value holds no object: open call on value derived from open argument keeps argument source.
kind_write!(::Type{Int}, values::Vector{Int}) = (values[1] = 0; nothing)
kind_write!(::Type{Float64}, values::Vector{Int}) = (values[1] = 1; nothing)
kind_write!(::Type{String}, ::Vector{Int}) = nothing
derived_write!(x::Any, values::Vector{Int}) = (kind_write!(promote_type(eltype(x), Int), values); nothing)
either_write!(x::Any, y::Any, flag::Bool, values::Vector{Int}) = (kind_write!(flag ? eltype(x) : eltype(y), values); nothing)
kind_on!(kind::Type, values::Vector{Int}) = (kind_write!(kind, values); nothing)
derived_through!(x::Any, values::Vector{Int}) = (kind_on!(eltype(x), values); nothing)
kind_after!(values::Vector{Int}, kinds::Type...) = (kind_write!(kinds[end], values); nothing)
derived_spread!(x::Any, values::Vector{Int}) = (kind_after!(values, Int, eltype(x)); nothing)
# Join where one member writes: operand type decides which member runs, so write takes its source.
half_write!(values::Vector{Int}) = (values[1] = 0; nothing)
half_write!(::Vector{Float64}) = nothing
half_join!(values::Union{Vector{Int}, Vector{Float64}}) = half_write!(values)
static_write!(::Type{T}, values::Vector{Int}) where {T} = (kind_write!(T, values); nothing)
static_both(values::Vector{T}, extra::T...) where {T} = nothing
typeof_write!(x::Any, values::Vector{Int}) = (kind_write!(typeof(x), values); nothing)
static_pair(::Type{T}, ::Type{S}) where {T, S} = nothing
derived_part!(x::Any, values::Vector{Int}) = (kind_write!((eltype(x), values)...); nothing)
derived_rest!(kinds::Vector{Type}, values::Vector{Int}) = (kind_after!(values, kinds...); nothing)
function derived_loop!(x::Any, values::Vector{Int}, count::Int)
    kind = Int
    for _ in 1:count
        kind_write!(kind, values)
        kind = eltype(x)
    end
    return nothing
end
object_at(pointer::Ptr{Cvoid}) = unsafe_pointer_to_objref(pointer)
unknown_foreign!(pointer::Ptr{Int}) = ccall(:corset_unknown_function, Cvoid, (Ptr{Int},), pointer)

# BLAS triangular solve (`trsv`) writes right-hand side; LAPACK LU solve (`gesv`) writes matrix and right-hand side.
solve_upper!(factor::UpperTriangular{Float64, Matrix{Float64}}, rhs::Vector{Float64})::Vector{Float64} = ldiv!(factor, rhs)
lu_solve!(matrix::Matrix{Float64}, rhs::Vector{Float64}) = LinearAlgebra.LAPACK.gesv!(matrix, rhs)
blas_dot(x::Vector{Float64}, y::Vector{Float64})::Float64 = LinearAlgebra.BLAS.dot(x, y)
# Same-named C function of other library, with fewer arguments than BLAS `axpy`, and with as many.
short_axpy!(pointer::Ptr{Float64}) = ccall(:daxpy_64_, Cvoid, (Ptr{Float64},), pointer)
other_axpy!(x::Vector{Float64}, y::Vector{Float64}) = ccall((:daxpy_64_, "libother"), Cvoid, (Ref{Int}, Ref{Float64}, Ptr{Float64}, Ref{Int}, Ptr{Float64}, Ref{Int}), 1, 1.0, x, 1, y, 1)
unknown_foreign_object!(x::Any) = ccall(:corset_unknown_function, Cvoid, (Any,), x)
mpfr_next!(x::BigFloat) = ccall((:mpfr_nextabove, Base.MPFR.libmpfr), Int32, (Ref{BigFloat},), x)
mpfr_compare(x::BigFloat, y::BigFloat) = ccall((:mpfr_less_p, Base.MPFR.libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), x, y)
mpfr_flag() = ccall((:mpfr_nanflag_p, Base.MPFR.libmpfr), Cint, ())
mpfr_clear_unknown!() = ccall((:mpfr_clear_flags, Base.MPFR.libmpfr), Cvoid, ())
mpfr_set_unknown!(x::Any) = ccall((:mpfr_corset_unknown, Base.MPFR.libmpfr), Cvoid, (Any,), x)
mpfr_add!(z::BigFloat, a::BigFloat, b::BigFloat) = ccall((:mpfr_add, Base.MPFR.libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, Base.MPFR.MPFRRoundingMode), z, a, b, Base.MPFR.ROUNDING_MODE[])
mpfr_airy(x::BigFloat) = (z = BigFloat(); ccall((:mpfr_ai, Base.MPFR.libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Int32), z, x, 0); z)
mpfr_airy_unknown(x::BigFloat) = (z = BigFloat(); ccall((:mpfr_corset_unknown, Base.MPFR.libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Int32), z, x, 0); z)
mpfr_lgamma_sign!(z::BigFloat, sign::Base.RefValue{Int32}, x::BigFloat) = ccall((:mpfr_lgamma, Base.MPFR.libmpfr), Int32, (Ref{BigFloat}, Ref{Int32}, Ref{BigFloat}, Int32), z, sign, x, 0)
mpfr_text(x::BigFloat, template::String, pointer::Base.RefValue{Ptr{UInt8}}) = ccall((:mpfr_asprintf, Base.MPFR.libmpfr), Cint, (Ptr{Ptr{UInt8}}, Ptr{UInt8}, Ref{BigFloat}...), pointer, template, x)
mpfr_exponent!(exponent::Base.RefValue{Clong}, y::BigFloat, x::BigFloat) = ccall((:mpfr_frexp, Base.MPFR.libmpfr), Int32, (Ptr{Clong}, Ref{BigFloat}, Ref{BigFloat}, Int32), exponent, y, x, 0)
popped(table::IdDict{Int, Vector{Int}}) = pop!(table, 1)
no_method(values::Vector{Int}) = sin(values)

"""
Written argument positions of MPFR and GMP functions, classified by hand from the manuals, independent of headers.
Left open: `mpfr_set_emin`, `mpfr_set_emax`, `mpfr_clear_flags`, `__gmp_set_memory_functions`, `__gmp_set_alloc_overflow_function`.
"""
const HANDWRITTEN = Dict{Symbol, Vector{Int}}(
    name => positions for (positions, names) in (
            # Output first, then inputs: MPFR 5.1 to 5.7, 5.11 to 5.12; GMP integer, rational functions.
            [1] => (
                :mpfr_set, :mpfr_set_d, :mpfr_set_si, :mpfr_set_ui, :mpfr_set_z, :mpfr_set_str, :mpfr_get_z,
                :mpfr_add, :mpfr_add_d, :mpfr_add_si, :mpfr_add_ui, :mpfr_add_z,
                :mpfr_sub, :mpfr_sub_d, :mpfr_sub_si, :mpfr_sub_ui, :mpfr_sub_z, :mpfr_d_sub, :mpfr_si_sub, :mpfr_ui_sub, :mpfr_z_sub,
                :mpfr_mul, :mpfr_mul_d, :mpfr_mul_si, :mpfr_mul_ui, :mpfr_mul_z, :mpfr_mul_2si, :mpfr_mul_2ui,
                :mpfr_div, :mpfr_div_d, :mpfr_div_si, :mpfr_div_ui, :mpfr_div_z, :mpfr_d_div, :mpfr_si_div, :mpfr_ui_div,
                :mpfr_fma, :mpfr_sqrt, :mpfr_cbrt, :mpfr_hypot, :mpfr_pow, :mpfr_pow_si, :mpfr_pow_ui, :mpfr_pow_z, :mpfr_neg, :mpfr_fac_ui,
                :mpfr_acos, :mpfr_acosh, :mpfr_asin, :mpfr_asinh, :mpfr_atan, :mpfr_atan2, :mpfr_atanh,
                :mpfr_cos, :mpfr_cosh, :mpfr_cospi, :mpfr_csc, :mpfr_csch, :mpfr_coth, :mpfr_sec, :mpfr_sech,
                :mpfr_sin, :mpfr_sinh, :mpfr_sinpi, :mpfr_tan, :mpfr_tanh, :mpfr_tanpi,
                :mpfr_acosu, :mpfr_asinu, :mpfr_atanu, :mpfr_atan2u, :mpfr_cosu, :mpfr_sinu, :mpfr_tanu,
                :mpfr_exp, :mpfr_exp10, :mpfr_exp2, :mpfr_expm1, :mpfr_log, :mpfr_log10, :mpfr_log2, :mpfr_log1p,
                :mpfr_eint, :mpfr_digamma, :mpfr_erf, :mpfr_erfc, :mpfr_gamma, :mpfr_gamma_inc, :mpfr_lngamma, :mpfr_zeta, :mpfr_beta,
                :mpfr_ai, :mpfr_j0, :mpfr_j1, :mpfr_jn, :mpfr_y0, :mpfr_y1, :mpfr_yn,
                :mpfr_ceil, :mpfr_floor, :mpfr_round, :mpfr_roundeven, :mpfr_trunc, :mpfr_fmod, :mpfr_remainder, :mpfr_copysign,
                :mpfr_const_log2, :mpfr_nextabove, :mpfr_nextbelow, :mpfr_asprintf,
                :__gmpz_set, :__gmpz_set_d, :__gmpz_set_si, :__gmpz_set_ui, :__gmpz_set_str,
                :__gmpz_add, :__gmpz_add_ui, :__gmpz_sub, :__gmpz_sub_ui, :__gmpz_ui_sub, :__gmpz_neg,
                :__gmpz_mul, :__gmpz_mul_si, :__gmpz_mul_ui, :__gmpz_mul_2exp,
                :__gmpz_cdiv_q, :__gmpz_cdiv_r, :__gmpz_fdiv_q, :__gmpz_fdiv_q_2exp, :__gmpz_fdiv_r, :__gmpz_tdiv_q, :__gmpz_tdiv_r,
                :__gmpz_pow_ui, :__gmpz_powm, :__gmpz_sqrt, :__gmpz_fac_ui, :__gmpz_bin_ui,
                :__gmpz_gcd, :__gmpz_lcm, :__gmpz_invert, :__gmpz_and, :__gmpz_ior, :__gmpz_xor, :__gmpz_com,
                :__gmpq_set, :__gmpq_set_z, :__gmpq_set_si, :__gmpq_set_ui, :__gmpq_add, :__gmpq_sub, :__gmpq_mul, :__gmpq_div,
                :__gmpz_init, :__gmpz_init2, :__gmpz_realloc2, :__gmpz_setbit, :__gmpz_limbs_finish, :__gmpq_canonicalize,
                :__gmpz_limbs_write, :__gmpz_get_str,
            ),
            [1, 2] => (:mpfr_sin_cos, :mpfr_modf, :mpfr_frexp, :mpfr_lgamma, :__gmpz_tdiv_qr, :__gmpz_export),
            [1, 2, 3] => (:__gmpz_gcdext,),
            # Comparisons, getters, predicates, flag getters, and freeing of C heap string.
            Int[] => (
                :mpfr_cmp_d, :mpfr_cmp_si, :mpfr_cmp_ui, :mpfr_cmp_z, :mpfr_equal_p, :mpfr_less_p, :mpfr_lessequal_p, :mpfr_integer_p,
                :mpfr_get_exp, :mpfr_get_prec, :__gmpfr_mpfr_get_sj, :__gmpfr_mpfr_get_uj, :mpfr_custom_get_size, :mpfr_get_version,
                :mpfr_get_patches, :mpfr_free_str, :mpfr_get_emax, :mpfr_get_emax_min, :mpfr_get_emax_max, :mpfr_get_emin,
                :mpfr_get_emin_min, :mpfr_get_emin_max, :mpfr_divby0_p, :mpfr_erangeflag_p, :mpfr_inexflag_p, :mpfr_nanflag_p,
                :mpfr_overflow_p, :mpfr_underflow_p, :__gmpz_cmp, :__gmpz_cmp_d, :__gmpz_cmp_si, :__gmpz_cmp_ui, :__gmpz_get_d,
                :__gmpz_popcount, :__gmpz_scan0, :__gmpz_scan1, :__gmpz_sizeinbase, :__gmpz_tstbit, :__gmpn_cmp, :__gmpn_popcount, :__gmpq_cmp,
            ),
        ) for name in names
)


"""Mutable cell that contract fixtures write through element."""
mutable struct Cell
    x::Int
end
pushed!(container::Any) = push!(container, 1)
measured(x::Any) = length(x)
iterated(x::Any) = iterate(x)
first_of_vector(x::AbstractVector) = first(x)
merged_any!(d::Any, e::Any) = merge!(d, e)
merged!(d::AbstractDict, e::AbstractDict) = merge!(d, e)
push_many!(c::Any, a::Vector{Int}, b::Vector{Int}) = push!(c, a, b)
"""Open store into `buf`: byte buffer converts value to `UInt8`, so it holds no object (JSON `_string`)."""
stored_into!(buf::AbstractVector, x::Any, i::Any) = (buf[i] = x; buf)
converted(T::Type, x::Any) = convert(T, x)
converted_fresh(T::Type, x::Vector{Int}) = convert(T, Any[x])
indexed(A::Any, mask::Vector{Int}) = A[mask]
view_write!(A::Any) = (view(A, 1)[1] = 0; nothing)
element_write!(A::Any) = ((A[1]::Cell).x = 0; nothing)
appended!(v::Vector{Int}, x::Any) = append!(v, x)
similar_of(A::Any) = similar(A)
contains_any(x::Any, c::Any) = x in c
got(d::Any, k::Int) = get(d, k, 0)
got_dict(d::AbstractDict, k::Int) = get(d, k, 0)
"""Keyword query reads keywords; keyword that may be callable runs as callback, so call stays open."""
rounded(x::Any) = round(x; digits = 2)
rounded_any(x::Any, digits::Any) = round(x; digits)
"""Keyword call of write contract with no rest role stays open."""
hinted!(v::Any) = sizehint!(v, 10; shrink = false)
"""Logger interface: `@warn` logs argument as keyword; `handle_message` writes logger only, as IO."""
warned(v::Vector{Int}) = (@warn "bad" v; nothing)
logged!(logger::Base.AbstractLogger, v::Vector{Int}) = Base.CoreLogging.handle_message(logger, Base.CoreLogging.Info, "m", @__MODULE__, :g, :id, "f", 1; v)
"""Deprecation warning calls `_depwarn` through `@invokelatest`."""
deprecated() = Base.depwarn("old", :deprecated)
"""Base selects logger method by `invoke` on `Tuple{typeof(logger)}`, which is not constant."""
catches(logger::Base.AbstractLogger) = Base.CoreLogging._invoked_catch_exceptions(logger)

"""Callable that holds object: constant binding to it reads binding."""
struct Adder
    n::Int
end
(adder::Adder)(v::Vector{Int}) = push!(v, adder.n)
const ADDER = Adder(1)
"""Binding that code can rebind: callee type stays open."""
rebound_callee::Any = push!
latest_push!(v::Vector{Int}) = @invokelatest push!(v, 1)
latest_round(x::Float64) = @invokelatest round(x; digits = 2)
latest_adder!(v::Vector{Int}) = @invokelatest ADDER(v)
latest_rebound!(v::Vector{Int}) = @invokelatest rebound_callee(v, 1)

@testset "builtin transfer" begin
    none, code, blind = NO_DOUBT, CODE_DOUBT, BLIND_DOUBT
    swapped = summary_of(swap_field!, Base.RefValue{Vector{Int}}, Vector{Int})
    @test doubts(swapped.writes) == Dict(top(2) => none) && doubts(swapped.reads) == Dict(top(2) => none)
    # Heap is flow-insensitive: old content holds stored value too.
    @test swapped.result == Nodes(Node.Placed(parameter(2, Step.Field(:x))) => none, Node.Placed(parameter(3)) => none)
    @test doubts(summary_of(modify_field!, Base.RefValue{Int}).writes) == Dict(top(2) => none)
    closure = summary_of(modify_closure!, Base.RefValue{Vector{Int}}, Vector{Int})
    @test closure.writes[memory((parameter(2, Step.Field(:x)), true))].doubt == code
    @test closure.writes[memory((parameter(3), true))].doubt == code
    @test haskey(summary_of(replace_field!, Base.RefValue{Vector{Int}}, Vector{Int}).edges, (Node.Placed(parameter(2)), Step.Field(:x)))
    @test doubts(summary_of(once_field!, Base.RefValue{Vector{Int}}, Vector{Int}).writes) == Dict(top(2) => none)
    named = summary_of(named_field!, Base.RefValue{Vector{Int}}, Symbol, Vector{Int})
    @test named.spread == Dict(Node.Placed(parameter(2)) => Nodes(Node.Placed(parameter(4)) => none))
    # Load of non-constant slot lies below same root: no doubt.
    @test named.result[Node.Placed(Place.Deep(Root.Parameter(2)))] == none
    here = @__MODULE__
    rebound = summary_of(rebind!, Vector{Int})
    # Global keeps old vector beside rebound one (no strong update), so sure write on `values` reads as `possible`.
    @test_broken doubts(rebound.writes) == Dict((global_place(here, :slot), false) => none, top(2) => none)
    @test rebound.bound == Dict(GlobalRef(here, :slot) => Nodes(Node.Placed(parameter(2)) => none))
    @test summary_of(swap_global!, Vector{Int}).result == Nodes(Node.Placed(global_place(here, :slot)) => none, Node.Placed(parameter(2)) => none)
    @test doubts(summary_of(modify_global!).writes) == Dict((global_place(here, :tally), false) => none)
    @test haskey(summary_of(replace_global!, Vector{Int}).writes, memory((global_place(here, :slot), false)))
    @test haskey(summary_of(once_global!, Vector{Int}).writes, memory((global_place(here, :loose), false)))
    named_global = summary_of(set_named!, Module, Symbol, Vector{Int})
    @test doubts(named_global.writes) == Dict((Place.At(Root.Elsewhere(), Step.Type[]), false) => code)
    @test named_global.spread == Dict(Node.Outside() => Nodes(Node.Placed(parameter(4)) => code))
    @test summary_of(get_named, Module, Symbol).result == Nodes(Node.Outside() => code)
    @test summary_of(get_slot).result == Nodes(Node.Placed(global_place(here, :slot)) => none)
    @test isempty(summary_of(read_holder).reads[memory((global_place(here, :HOLDER), false))].reason)
    @test doubts(summary_of(memory_get, Memory{Vector{Int}}).reads) == Dict(top(2) => none)
    @test summary_of(memory_get, Memory{Vector{Int}}).result == Nodes(Node.Placed(parameter(2, Step.Element())) => none)
    for writer in (memory_once!, memory_swap!, memory_modify!, memory_replace!)
        @test summary_of(writer, Memory{Vector{Int}}, Vector{Int}).writes[memory(top(2))].doubt == none
    end
    @test doubts(summary_of(memory_assigned, Memory{Vector{Int}}).reads) == Dict(top(2) => none)
    @test summary_of(fresh_memory).fresh == 1
    @test last(only(keys(summary_of(wrapped, Vector{Int}).edges))) == Step.Position(1)
    @test only(values(summary_of(wrapped, Vector{Int}).edges)) == Nodes(Node.Placed(parameter(2)) => none)
    @test summary_of(unwrapped, Vector{Int}).result == Nodes(Node.Placed(parameter(2)) => none)
    @test summary_of(barrier, Vector{Int}).result == Nodes(Node.Placed(parameter(2)) => none)
    @test summary_of(either, Bool, Vector{Int}, Vector{Int}).result == Nodes(Node.Placed(parameter(3)) => none, Node.Placed(parameter(4)) => none)
    @test summary_of(scope).result == Nodes(Node.Outside() => code)
    @test summary_of(asserted, Any).result == Nodes(Node.Placed(parameter(2)) => none)
    @test isempty(summary_of(define, DataType).writes)
end

@testset "intrinsic and foreign call transfer" begin
    none, code = NO_DOUBT, CODE_DOUBT
    for writer in (pointer_set!, pointer_swap!, pointer_modify!, pointer_replace!)
        @test summary_of(writer, Ptr{Int}).writes[memory(top(2))].doubt == none
    end
    @test doubts(summary_of(pointer_get, Ptr{Int}).reads) == Dict(top(2) => none)
    @test summary_of(wrap_store!, Memory{Int}).writes[memory(top(2))].doubt == none
    for writer in (wrap_set!, wrap_pop!)
        @test summary_of(writer, Memory{Int}).writes[memory(top(2))].doubt == code
    end
    @test summary_of(llvm, Ptr{Int}).result == Nodes(Node.Placed(parameter(2)) => code, Node.Outside() => code)
    @test summary_of(llvm, Ptr{Int}).writes[memory((parameter(2), true))].doubt == code
    @test summary_of(global_pointer).result == Nodes(Node.Outside() => code)
    @test summary_of(library_pointer).result == Nodes(Node.Outside() => code)
    # Open pointer type derives sources from operands, library tuple expression among them.
    @test summary_of(open_pointer, Type) isa Summary
    # Null pointer global points into no object, so `Cstring` error path writes no `C_NULL`.
    @test all(((place, _),) -> root_of(place) != Root.Global(GlobalRef(Base, :C_NULL)), keys(summary_of(length_of, String).writes))
    @test null_pointer(GlobalRef(Base, :C_NULL)) && !null_pointer(GlobalRef(@__MODULE__, :HOLDER)) && !null_pointer(GlobalRef(@__MODULE__, :slot))
    # Compiler inlines `C_NULL` into `uv_random` call: null literal points into no object, so open call writes buffer only.
    @test all(((place, _, _),) -> root_of(place) == Root.Parameter(2), keys(summary_of(Base.Libc.getrandom!, Base.RefValue{UInt64}).writes))
    @test summary_of(object_at, Ptr{Cvoid}).result == Nodes(Node.Placed(parameter(2)) => none)
    @test doubts(summary_of(unknown_foreign!, Ptr{Int}).writes) == Dict((parameter(2), true) => code)
    # Unknown C function: doubt in code, also on argument of open type.
    @test doubts(summary_of(unknown_foreign_object!, Any).writes) == Dict((parameter(2), true) => code)
    popped_summary = summary_of(popped, IdDict{Int, Vector{Int}})
    @test doubts(popped_summary.writes) == Dict(top(2) => none) && popped_summary.result == Nodes(Node.Placed(parameter(2, Step.Element())) => none)
    for (target, name) in ((QuoteNode(:strlen), :strlen), (Expr(:tuple, QuoteNode(:f), "lib"), :f), ((:f, "lib"), :f), ("f", :f), (Expr(:tuple), nothing), ((), nothing), (1, nothing))
        @test foreign_name(target) === name
    end
    # Library comes from second part of target, quoted or not; symbol alone names none.
    for (target, library) in ((QuoteNode((:f, "lib")), "lib"), (Expr(:tuple, QuoteNode(:f), QuoteNode("lib")), "lib"), ((:f, "lib"), "lib"), (QuoteNode(:f), nothing), ((:f, 1), nothing))
        @test foreign_library(target) == library
    end
end

@testset "MPFR and GMP foreign calls" begin
    none = NO_DOUBT
    effects(name::Symbol)::Tuple = (f = FOREIGN_EFFECTS[name]; (f.writes, f.reads, f.result))
    # Audited writes (repair of `BigFloat` limb pointer) touch every operand; only memory writes count.
    written(f::Any, types::Type...)::Set{Int} = Set(position for position in 1:8 if any(((place, _, kind),) -> kind == EffectKind.memory && root_of(place) == Root.Parameter(position), keys(summary_of(f, types...).writes)))
    for (name, positions) in HANDWRITTEN
        @test FOREIGN_EFFECTS[name].writes == positions
    end
    # Header roles: `mpfr_ptr` writes, `mpfr_srcptr` and scalars read or skip.
    @test effects(:mpfr_add) == ([1], [2, 3], Int[])
    @test effects(:mpfr_sin_cos) == ([1, 2], [3], Int[])
    @test effects(:mpfr_get_d) == (Int[], [1], Int[])
    @test effects(:__gmpz_add) == ([1], [2, 3], Int[])
    @test effects(:mpfr_strtofr) == ([1, 3], [2], Int[])
    @test effects(:__gmpz_export)[3] == [1] && effects(:__gmpz_limbs_write)[3] == [1]
    open_names = Set([:mpfr_set_emin, :mpfr_set_emax, :mpfr_clear_flags, :__gmp_set_memory_functions, :__gmp_set_alloc_overflow_function])
    @test isdisjoint(open_names, keys(FOREIGN_EFFECTS))
    # Every MPFR and GMP function that Base calls has an entry or stays open on purpose.
    called = Set{Symbol}()
    Base.visit(Core.methodtable) do method
        method.module in (Base.MPFR, Base.GMP, Base.GMP.MPZ, Base.GMP.MPQ) || return nothing
        foreach(statement -> statement isa Expr && statement.head === :foreigncall && push!(called, foreign_name(statement.args[1])), Base.uncompressed_ast(method).code)
    end
    mine = filter(name -> startswith(string(name), r"mpfr_|__gmp"), called)
    @test isempty(setdiff(mine, keys(FOREIGN_EFFECTS), open_names))
    @test isempty(setdiff(mine, keys(HANDWRITTEN), open_names))
    # Positive: output arguments take definite writes, inputs stay unwritten.
    @test doubts(summary_of(Base.GMP.MPZ.add!, BigInt, BigInt, BigInt).writes) == Dict(top(2) => none)
    @test doubts(summary_of(Base.GMP.MPZ.tdiv_qr!, BigInt, BigInt, BigInt, BigInt).writes) == Dict(top(2) => none, top(3) => none)
    @test written(Base.GMP.MPZ.gcdext!, BigInt, BigInt, BigInt, BigInt, BigInt) == Set([2, 3, 4])
    @test written(Base.GMP.MPZ.setbit!, BigInt, Int) == Set([2])
    @test written(Base.GMP.MPZ.cmp, BigInt, BigInt) == written(Base.GMP.MPZ.popcount, BigInt) == Set{Int}()
    @test doubts(summary_of(mpfr_lgamma_sign!, BigFloat, Base.RefValue{Int32}, BigFloat).writes)[(parameter(3), false)] == none
    @test written(mpfr_exponent!, Base.RefValue{Clong}, BigFloat, BigFloat) == Set([2, 3])
    @test written(mpfr_text, BigFloat, String, Base.RefValue{Ptr{UInt8}}) == Set([4])
    # Negative: `BigFloat` input stays unwritten, as in SpecialFunctions `airyai`; unknown MPFR function writes it possibly.
    for (f, types) in ((mpfr_airy, (BigFloat,)), (mpfr_compare, (BigFloat, BigFloat)), (mpfr_flag, ()), (+, (BigFloat, BigFloat)), (sin, (BigFloat,)))
        @test isempty(written(f, types...))
    end
    @test written(mpfr_airy_unknown, BigFloat) == Set([2])
    # Output operand `BigFloat` gets the write: wrapper `x.d` stands for memory of `x`.
    @test written(mpfr_add!, BigFloat, BigFloat, BigFloat) == Set([2])
    @test summary_of(mpfr_add!, BigFloat, BigFloat, BigFloat).writes[(parameter(2), false, EffectKind.memory)].doubt == none
    @test written(mpfr_next!, BigFloat) == Set([2])
    @test written(mpfr_clear_unknown!) == Set{Int}()
    @test written(mpfr_set_unknown!, Any) == Set([2])
end

@testset "BLAS and LAPACK foreign calls" begin
    none = NO_DOUBT
    effects(name::Symbol)::Tuple = (f = BLAS_EFFECTS[name]; (f.writes, f.reads))
    # Role comments: `[in,out] X` of `trsv` read and written, `[out] IPIV` of `gesv` written, `[in]` read.
    @test effects(:dtrsv_64_) == ([7], collect(1:8))
    @test effects(:dgesv_64_) == ([3, 5, 6, 8], [1, 2, 3, 4, 6, 7])
    # `?ormrz` modifies `A` and restores it: store counts as write.
    @test 7 in first(effects(:dormrz_64_))
    # Renamed `?gemmt` takes roles of `?gemmtr`; CBLAS dot reads, `_sub` form writes output.
    @test effects(:zgemmt_64_) == ([12], collect(1:13))
    @test effects(:cblas_ddot64_) == (Int[], [2, 4]) && effects(:cblas_zdotc_sub64_) == ([6], [2, 4])
    # Every BLAS and LAPACK call of LinearAlgebra, by global or literal library, has entry; `lbt_` configuration stays open.
    targets = Set{Any}()
    Base.visit(Core.methodtable) do method
        method.module in (LinearAlgebra, LinearAlgebra.BLAS, LinearAlgebra.LAPACK) || return nothing
        foreach(statement -> statement isa Expr && statement.head === :foreigncall && push!(targets, statement.args[1]), Base.uncompressed_ast(method).code)
    end
    blas = filter(target -> haskey(BLAS_EFFECTS, foreign_name(target)), targets)
    @test length(blas) > 400 && all(!isnothing ∘ foreign_effects, blas)
    @test all(target -> target in blas || startswith(string(foreign_name(target)), "lbt_") || haskey(FOREIGN_EFFECTS, foreign_name(target)), targets)
    # Solve writes right-hand side for sure and leaves factor unwritten; dot writes nothing.
    @test doubts(summary_of(solve_upper!, UpperTriangular{Float64, Matrix{Float64}}, Vector{Float64}).writes) == Dict(top(3) => none)
    @test doubts(summary_of(lu_solve!, Matrix{Float64}, Vector{Float64}).writes) == Dict(top(2) => none, top(3) => none)
    @test isempty(summary_of(blas_dot, Vector{Float64}, Vector{Float64}).writes)
    # Call that passes fewer arguments than entry names stays open, as unknown C function does.
    @test doubts(summary_of(short_axpy!, Ptr{Float64}).writes) == Dict((parameter(2), true) => CODE_DOUBT)
    # Library name with version and platform suffix is BLAS library; other name that shares prefix is not.
    @test all(blas_library, ("libblastrampoline.so.5", "/lib/libblastrampoline.5.dylib", "libblastrampoline-5.dll", "libopenblas64_.so", "libblastrampoline"))
    @test !any(blas_library, ("libblastrampoline_custom.so", "libopenblas.so", "libother.so.5"))
    # BLAS name in other library stays open: possible write on both arrays.
    @test doubts(summary_of(other_axpy!, Vector{Float64}, Vector{Float64}).writes) == Dict((parameter(2), true) => CODE_DOUBT, (parameter(3), true) => CODE_DOUBT)
    # Complex `geqp3!` holds dead real call with fewer arguments: it adds no open write.
    @test doubts(summary_of(LinearAlgebra.LAPACK.geqp3!, Matrix{ComplexF32}, Vector{Int}, Vector{ComplexF32}).writes) == Dict(top(2) => none, top(3) => none, top(4) => none)
end

@testset "statements and calls" begin
    none, code, blind = NO_DOUBT, CODE_DOUBT, BLIND_DOUBT
    @test fresh_spread(summary_of(quoted, Vector{Int})) == Nodes(Node.Placed(parameter(2)) => none)
    @test fresh_spread(summary_of(call_quoted, Vector{Int})) == Nodes(Node.Placed(parameter(2)) => none)
    @test any(nodes -> haskey(nodes, Node.Placed(parameter(2))), values(summary_of(opaque, Vector{Int}).spread))
    @test Node.Placed(parameter(2)) in keys(only(values(summary_of(splat, Vector{Int}).edges)))
    @test fresh_spread(summary_of(splat_vararg, Tuple{Vararg{Vector{Int}}})) == Nodes(Node.Placed(Place.Deep(Root.Parameter(2))) => none)
    caught_summary = summary_of(caught, Vector{Int})
    @test any(nodes -> haskey(nodes, Node.Outside()), values(caught_summary.edges))
    for (pusher, types) in ((latest!, (Vector{Int},)), (world!, (Vector{Int},)), (invoked!, (Vector{Int},)), (spread!, (Vector{Int}, Tuple{Int, Int})), (nested_spread!, (Vector{Int}, Tuple{Tuple{Int}})))
        @test summary_of(pusher, types...).writes[memory(top(2))].doubt == none
    end
    @test isempty(summary_of(invoke_dead, String).writes)
    @test summary_of(invoke_open, Vector{Int}, Type).writes[memory((parameter(2), true))].doubt == code
    @test doubts(summary_of(invoke_contract!, Vector{Int}, Type).writes) == Dict(top(2) => none)
    @test summary_of(invoke_missing, Vector{Int}).writes[memory((parameter(2), true))].doubt == code
    # Tuple of unknown length dispatches on `Vararg`: `push!` contract writes `values` only.
    @test doubts(summary_of(spread_rest!, Vector{Int}, Tuple{Vararg{Int}}).writes) == Dict(top(2) => none)
    # Open dispatch on `::Any` argument: its type is source of doubt, so caller provenance decides.
    @test summary_of(dynamic!, Any).writes[memory((parameter(2), true))].doubt == sourced(2)
    # No method matches: call throws, so it writes and reads nothing.
    @test isempty(summary_of(no_method, Vector{Int}).writes) && isempty(summary_of(no_method, Vector{Int}).reads)
    @test summary_of(nested_apply, Vector{Int}, Tuple{Tuple{Int}}).writes[memory((parameter(2), true))].doubt == code
    # Constant object in code is one object outside caller places: result aliases it without doubt.
    @test summary_of(embedded).result == Nodes(Node.Outside() => none)
    @test summary_of(unknown_field, Module, Symbol).result == Nodes(Node.Outside() => code)
    @test summary_of(unknown_any, Module, Symbol, Symbol).result == Nodes(Node.Outside() => code)
    @test haskey(summary_of(first_of_fresh, Vector{Int}).result, Node.Placed(parameter(2)))
    @test haskey(summary_of(any_of_fresh, Vector{Int}, Symbol).result, Node.Placed(parameter(2)))
    @test summary_of(field_global).result == Nodes(Node.Placed(global_place(@__MODULE__, :slot)) => none)
    @test summary_of(make_backed, Vector{Int}).result == Nodes(Node.Placed(parameter(2)) => none)
    run = start_run(nothing, Module[])
    instance = only(something(dispatch(Any[typeof(broken), Int], run.world, 1)))
    @test library_body!(run, instance) == "inference gave no code"
    @test summary_of(calls_broken, Vector{Int}).writes == Dict()
    broken_int = summary_of(x -> broken(x), Int)
    @test isempty(broken_int.writes)
    # Phi joins both branches: run-time `flag` picks written vector, so write is `possible` on each.
    @test doubts(summary_of(pick!, Vector{Int}, Vector{Int}, Bool).writes) == Dict(top(2) => code, top(3) => code)
    # Blind alternative leaves choice open too: known object gets `possible` write, blind one keeps its blind spot.
    chosen, table = Origin.Caller(parameter(2)), Summaries.OriginAccesses()
    either = Targets(chosen => none, Origin.Unknown() => blind)
    Summaries.alternative_access!(table, either, either, false, Effect(none, 1, ""), EffectKind.memory)
    @test table[(chosen, false, EffectKind.memory)].doubt == code && level_of(table[(Origin.Unknown(), false, EffectKind.memory)].doubt) == Level.blind
    # Two known objects below one argument: write below it is sure, unless blind origin may take run-time choice.
    left, right = Origin.Caller(parameter(2, Step.Field(:left))), Origin.Caller(parameter(2, Step.Field(:right)))
    for (extra, expected) in ((Targets(), none), (Targets(Origin.Unknown() => blind), code))
        three, pair = Summaries.OriginAccesses(), merge(Targets(left => none, right => none), extra)
        Summaries.alternative_access!(three, pair, pair, false, Effect(none, 1, ""), EffectKind.memory)
        @test three[(chosen, true, EffectKind.memory)].doubt == expected && three[(left, false, EffectKind.memory)].doubt == code
    end
    # One origin keeps write certainty.
    single = Summaries.OriginAccesses()
    Summaries.alternative_access!(single, Targets(chosen => none), Targets(chosen => none), false, Effect(none, 1, ""), EffectKind.memory)
    @test single[(chosen, false, EffectKind.memory)].doubt == none
    # Write below fresh object may land on it alone: caller object inside it gets `possible` write.
    wrapper, wrapped = Origin.Allocation(1), Summaries.OriginAccesses()
    Summaries.alternative_access!(wrapped, Targets(wrapper => none), Targets(wrapper => none, chosen => none), true, Effect(none, 1, ""), EffectKind.memory)
    @test wrapped[(wrapper, true, EffectKind.memory)].doubt == none && wrapped[(chosen, true, EffectKind.memory)].doubt == code
    # `copy(::Memory{Nothing})` writes fresh memory or its data pointer: source elements copied into it stay `possible`.
    @test all(effect -> level_of(effect.doubt) != Level.none, values(summary_of(copy, Set{Vector{Int}}).writes))
    # Fresh objects escape through globals and caller objects. Store keeps old content (no strong update): sure write reads as `possible`.
    @test_broken summary_of(held_write!, Vector{Int}).writes[memory(top(2))].doubt == none
    @test_broken summary_of(nest_write!, Base.RefValue{Base.RefValue{Vector{Int}}}, Vector{Int}).writes[memory(top(3))].doubt == none
    # Callee access below fresh wrapper reaches caller object inside; open result keeps source of open callee.
    @test summary_of(open_wrapped!, Any, Vector{Int}).writes[memory((parameter(3), true))].doubt == sourced(2)
    # Open callee picks result, so doubt keeps its source; alternative objects add doubt in code.
    @test_broken summary_of(open_result_write!, Any, Vector{Int}).writes[memory(top(3))].doubt == sourced(2)
    # Callee source maps to caller argument in its position: effects, result nodes and unknown objects alike.
    swapped = summary_of(open_result_swapped, Vector{Int}, Any)
    @test doubts(swapped.writes) == Dict((parameter(2), true) => sourced(3), (parameter(3), true) => sourced(3))
    @test swapped.result == Nodes(Node.Placed(parameter(2)) => sourced(3), Node.Placed(parameter(3)) => sourced(3), Node.Outside() => sourced(3))
    @test summary_of(open_unknown_through!, Any, Any).writes[memory((Place.At(Root.Elsewhere(), Step.Type[]), true))].doubt == sourced(3)
    @test summary_of(open_loaded!, Any).writes[memory((Place.At(Root.Elsewhere(), Step.Type[]), true))].doubt == sourced(2)
    @test summary_of(open_loaded_any!, Any, Symbol).writes[memory((Place.At(Root.Elsewhere(), Step.Type[]), true))].doubt == sourced(2)
    # Type value derived from open argument keeps its source: through call, phi, callee parameter and vararg tuple.
    @test summary_of(derived_write!, Any, Vector{Int}).writes[memory((parameter(3), true))].doubt == sourced(2)
    @test summary_of(either_write!, Any, Any, Bool, Vector{Int}).writes[memory((parameter(5), true))].doubt == sourced(2, 3)
    @test summary_of(kind_on!, Type, Vector{Int}).writes[memory((parameter(3), true))].doubt == sourced(2)
    @test summary_of(derived_through!, Any, Vector{Int}).writes[memory((parameter(3), true))].doubt == sourced(2)
    @test summary_of(derived_spread!, Any, Vector{Int}).writes[memory((parameter(3), true))].doubt == sourced(2)
    @test summary_of(derived_part!, Any, Vector{Int}).writes[memory((parameter(3), true))].doubt == sourced(2)
    @test summary_of(static_write!, Type, Vector{Int}).writes[memory((parameter(3), true))].doubt == sourced(2)
    joined_run = start_run(nothing, Module[@__MODULE__])
    joined_root = (only(something(dispatch(Any[typeof(half_join!), Union{Vector{Int}, Vector{Float64}}], joined_run.world, 1))), Pair{Int, Any}[])
    solve!(joined_run, [joined_root])
    @test root_summary!(joined_run, joined_root).writes[memory(top(2))].doubt == sourced(2)
    # `DataType` value dispatches on type it holds: `typeof(x)` keeps source of `x`.
    @test summary_of(typeof_write!, Any, Vector{Int}).writes[memory((parameter(3), true))].doubt == sourced(2)
    @test summary_of(derived_rest!, Vector{Type}, Vector{Int}).writes[memory((parameter(3), true))].doubt == sourced(2)
    # Loop brings source to earlier call in later round: last round decides doubt.
    @test summary_of(derived_loop!, Any, Vector{Int}, Int).writes[memory((parameter(3), true))].doubt == sourced(2)
    # Function stand-in stands for any callee Corset chose: its call stays open, with or without keywords.
    @test summary_of(open_on!, FunctionStandIn, Vector{Int}).writes[memory((parameter(3), true))].doubt == Doubt(Level.code, OPAQUE)
    @test summary_of(open_keywords!, FunctionStandIn, Vector{Int}).writes[memory((parameter(3), true))].doubt == Doubt(Level.code, OPAQUE)
    @test all(((place, _),) -> root_of(place) != Root.Parameter(3), keys(summary_of(open_element!, Any, Vector{Int}).writes))
    mktempdir(@__DIR__) do directory
        journal = open_journal(directory)
        try
            target = only(something(dispatch(Any[typeof(push!), Vector{Int}, Int], run.world, 1)))
            push!(journal.crashed, journal_key(target))
            crashed = start_run(journal, Module[])
            root = (only(something(dispatch(Any[typeof(latest!), Vector{Int}], crashed.world, 1))), Pair{Int, Any}[])
            solve!(crashed, [root])
            effect = held_summary(crashed.slots, root).writes[memory((parameter(2), true))]
            @test effect.doubt == blind && effect.reason == "inference crashed process"
            fresh = start_run(journal, Module[])
            other = (only(something(dispatch(Any[typeof(fill_one!), Vector{Int}], fresh.world, 1))), Pair{Int, Any}[])
            solve!(fresh, [other])
            @test any(record -> startswith(record.key, "effects\n") && record.finished, records(directory))
        finally
            close(journal.io)
        end
    end
end

@testset "Base contracts" begin
    none, code = NO_DOUBT, CODE_DOUBT
    # Write contract keeps certainty; verdict assumes methods loaded now keep contract.
    for (writer, types) in ((pushed!, (Any,)), (merged!, (AbstractDict, AbstractDict)), (view_write!, (Any,)))
        @test doubts(summary_of(writer, types...).writes) == Dict(top(2) => none) && summary_of(writer, types...).closed_world
    end
    many = summary_of(push_many!, Any, Vector{Int}, Vector{Int})
    @test many.edges[(Node.Placed(parameter(2)), Step.Element())] == Nodes(Node.Placed(parameter(3)) => none, Node.Placed(parameter(4)) => none)
    # Element type that points to no object takes no store; write stays.
    bytes, objects = summary_of(stored_into!, AbstractVector{UInt8}, Any, Any), summary_of(stored_into!, AbstractVector{Any}, Any, Any)
    @test !haskey(bytes.edges, (Node.Placed(parameter(2)), Step.Element())) && haskey(doubts(bytes.writes), top(2))
    @test objects.edges[(Node.Placed(parameter(2)), Step.Element())] == Nodes(Node.Placed(parameter(3)) => none)
    # Queries write nothing; result may alias argument (`convert`) or be element (`get`); `similar` result is fresh.
    for (query, types) in ((measured, (Any,)), (first_of_vector, (AbstractVector,)), (similar_of, (Any,)), (got_dict, (AbstractDict, Int)))
        @test isempty(summary_of(query, types...).writes) && summary_of(query, types...).closed_world
    end
    @test summary_of(converted, Type, Any).result == Nodes(Node.Placed(parameter(3)) => code)
    # Plain query result is new value: aliasing it cost JSON 3 times `effects` time.
    @test isempty(summary_of(measured, Any).result)
    # Element query result lies in collection, never in indices.
    @test haskey(summary_of(indexed, Any, Vector{Int}).result, Node.Placed(parameter(2))) && !haskey(summary_of(indexed, Any, Vector{Int}).result, Node.Placed(parameter(3)))
    # Result may point beneath fresh argument: caller object inside it. `Any[x]` allocation is blind already.
    @test haskey(summary_of(converted_fresh, Type, Vector{Int}).result, Node.Placed(parameter(3)))
    @test summary_of(got_dict, AbstractDict, Int).result == Nodes(Node.Placed(parameter(2, Step.Element())) => none)
    @test isempty(summary_of(similar_of, Any).result)
    # Run-time type of `A` decides which object `A[1]` gives: write is `possible` on each and below their common place.
    @test doubts(summary_of(element_write!, Any).writes) == Dict((parameter(2, Step.Element()), false) => code, top(2) => code, (parameter(2), true) => code)
    # Argument that admits consumed iterator (`Iterators.Stateful`) gets `possible` write; its type decides breach.
    @test doubts(summary_of(iterated, Any).writes) == Dict(top(2) => sourced(2))
    @test doubts(summary_of(contains_any, Any, Any).writes) == Dict(top(3) => sourced(3))
    @test doubts(summary_of(appended!, Vector{Int}, Any).writes) == Dict(top(2) => none, top(3) => sourced(3))
    # First argument that may be callable selects callback form: call stays open.
    @test doubts(summary_of(merged_any!, Any, Any).writes) == Dict((parameter(2), true) => sourced(2, 3), (parameter(3), true) => sourced(2, 3))
    @test doubts(summary_of(got, Any, Int).writes) == Dict((parameter(2), true) => sourced(2))
    # Keyword query reads keywords; callable keyword, or contract without rest role that only reads, keeps call open.
    @test isempty(summary_of(rounded, Any).writes) && summary_of(rounded, Any).closed_world
    @test doubts(summary_of(rounded_any, Any, Any).writes) == Dict((parameter(2), true) => sourced(2, 3), (parameter(3), true) => sourced(2, 3))
    @test doubts(summary_of(hinted!, Any).writes) == Dict((parameter(2), true) => sourced(2))
    # Keyword tuple with abstract value takes upper bound of its value tuple.
    @test keyword_types(NamedTuple{(:a,), <:Tuple{Tuple{Any}}}) == [Tuple{Any}] && keyword_types(@NamedTuple{a::Int}) == [Int]
    @test isnothing(keyword_types(Int)) && isnothing(keyword_types(NamedTuple))
    # Logger interface: `handle_message` writes logger as IO; logged value takes no write. `@warn` uses global logger.
    @test doubts(summary_of(logged!, Base.AbstractLogger, Vector{Int}).writes) == Dict((parameter(2), false, EffectKind.io) => none)
    logger = (Place.At(Root.Global(GlobalRef(Base.CoreLogging, :_global_logstate)), Step.Type[Step.Field(:logger)]), false, EffectKind.io)
    warned_writes = summary_of(warned, Vector{Int}).writes
    @test haskey(warned_writes, logger) && all(((place, _, _),) -> root_of(place) != Root.Parameter(2), keys(warned_writes))
    @test haskey(summary_of(deprecated).writes, logger)
    @test isempty(summary_of(catches, Base.AbstractLogger).writes) && summary_of(catches, Base.AbstractLogger).closed_world
end

@testset "latest-world calls" begin
    none = NO_DOUBT
    # `@invokelatest` with constant `GlobalRef` resolves as direct call, with or without keywords.
    @test doubts(summary_of(latest_push!, Vector{Int}).writes) == Dict(top(2) => none)
    @test isempty(summary_of(latest_round, Float64).writes)
    # Constant binding takes its value in analysis world: IR world range starts before `ADDER` exists.
    @test doubts(summary_of(latest_adder!, Vector{Int}).writes) == Dict(top(2) => none)
    # Binding that code can rebind leaves callee open: binding and argument take `possible` write.
    rebound = doubts(summary_of(latest_rebound!, Vector{Int}).writes)
    @test rebound == Dict((parameter(2), true) => CODE_DOUBT, (global_place(@__MODULE__, :rebound_callee), true) => CODE_DOUBT)
end

first_of!(x::Vector{Int}, rest::Vector{Int}...) = (x[1] = 0; nothing)
first_rest!(n::Int, rest::Vector{Int}...) = (rest[1][1] = n; nothing)
spread_first!(xs::Vector{Vector{Int}}) = first_of!(xs...)
spread_rest_first!(a::Vector{Int}, xs::Vector{Vector{Int}}) = first_rest!(1, a, xs...)
spread_tuple!(xs::Tuple{Vararg{Vector{Int}}}) = first_of!(xs...)
spread_then!(xs::Vector{Vector{Int}}, a::Vector{Int}) = first_of!(xs..., a)
spread_packed(xs::Vector{Vector{Int}}) = tuple(xs...)
spread_pushed!(v::Vector{Vector{Int}}, xs::Vector{Vector{Int}}) = push!(v, xs...)
spread_builtin_callee(fs::Vector{typeof(setfield!)}) = Base.invokelatest(fs...)
spread_set!(A::Vector{Int}, xs::Vector{Int}) = setindex!(A, xs...)
spread_field(xs::Vector{Any}) = getfield(xs...)
spread_latest(xs::Vector{Any}) = Base.invokelatest(xs...)
spread_set_max(s::Set{Vector{Int}}) = max(s...)

@testset "Spread calls" begin
    none, code, blind = NO_DOUBT, CODE_DOUBT, BLIND_DOUBT
    # Array of unknown length: parameters past fixed operands take any element.
    @test doubts(summary_of(spread_first!, Vector{Vector{Int}}).writes) == Dict((parameter(2, Step.Element()), false) => none)
    # Vararg tuple holds fixed operand at its position and spread elements in unknown slot, which every position reads.
    # Position 1 joins `a` with spread elements, so write is `possible` on each; exact answer is sure write on `a` alone.
    @test doubts(summary_of(spread_rest_first!, Vector{Int}, Vector{Vector{Int}}).writes) == Dict(top(2) => code, (parameter(3, Step.Element()), false) => code)
    # Operand after spread of unknown length has unknown position too: run-time length of `xs` picks written vector.
    @test doubts(summary_of(spread_then!, Vector{Vector{Int}}, Vector{Int}).writes) == Dict((parameter(2, Step.Element()), false) => code, top(3) => code)
    # Caller tuple slot of unknown position collapses; write below it keeps certainty.
    @test doubts(summary_of(spread_tuple!, Tuple{Vararg{Vector{Int}}}).writes) == Dict((Place.Deep(Root.Parameter(2)), false) => none)
    # Spread callee stays open: method table matches builtin method `setfield!(...)` for `Vararg` callee.
    # Singleton function elements hold no object, so open call writes nothing.
    @test isempty(summary_of(spread_builtin_callee, Vector{typeof(setfield!)}).writes)
    @test fresh_spread(summary_of(spread_packed, Vector{Vector{Int}})) == Nodes(Node.Placed(parameter(2, Step.Element())) => none)
    # Contract holds when spread falls on its vararg role.
    pushed = summary_of(spread_pushed!, Vector{Vector{Int}}, Vector{Vector{Int}})
    @test doubts(pushed.writes) == Dict(top(2) => none) && pushed.edges[(Node.Placed(parameter(2)), Step.Element())] == Nodes(Node.Placed(parameter(3, Step.Element())) => none)
    # Spread before contract role, into builtin, as callee, or of collection with own `iterate`: open.
    # Open call takes spread elements, not array itself; `Int` elements hold no object.
    @test doubts(summary_of(spread_set!, Vector{Int}, Vector{Int}).writes) == Dict((parameter(2), true) => code)
    # Builtin of unknown argument count: doubt in code. Spread callee: element type decides.
    @test doubts(summary_of(spread_field, Vector{Any}).writes) == Dict((parameter(2, Step.Element()), true) => code)
    @test doubts(summary_of(spread_latest, Vector{Any}).writes) == Dict((parameter(2, Step.Element()), true) => sourced(2))
    @test doubts(summary_of(spread_set_max, Set{Vector{Int}}).writes) == Dict((parameter(2), true) => code)
end

"""Summary with `fresh` fresh nodes and stores `edges`, memory `backing` and unknown-slot `spread`; it accesses nothing."""
function fresh_summary(fresh::Integer, edges::Edges, backing::Holds, spread::Holds)::Summary
    return Summary(Accesses(), Accesses(), edges, backing, spread, Dict{GlobalRef, Nodes}(), Set{Callback}(), Nodes(), fresh, false, false, HoldCounts(), HoldCounts(), Dict{Tuple{Node.Type, Resource.T}, Unguarded}())
end

"""Summary with `fresh` fresh nodes and no stores."""
fresh_summary(fresh::Integer)::Summary = fresh_summary(fresh, Edges(), Holds(), Holds())

"""Function with `JOIN_LIMIT` methods: call on `Any` joins them."""
three_way(x::Int) = x
three_way(x::Float64) = x
three_way(x::String) = x

"""Function with one method past `JOIN_LIMIT`: call on `Any` stays open."""
four_way(x::Int) = x
four_way(x::Float64) = x
four_way(x::String) = x
four_way(x::Symbol) = x

@testset "model and helpers" begin
    @test most(most(NO_DOUBT, CODE_DOUBT), BLIND_DOUBT) == BLIND_DOUBT
    # Two `code` doubts join sources, both along chain and across chains.
    @test most(sourced(2), sourced(3)) == sourced(2, 3) && least(sourced(2), CODE_DOUBT) == Doubt(Level.code, parameter_source(2) | INHERENT)
    @test least(NO_DOUBT, sourced(2)) == NO_DOUBT && least(BLIND_DOUBT, sourced(2)) == sourced(2) && most(sourced(2), NO_DOUBT) == sourced(2)
    @test parameter_source(LAST_PARAMETER + 1) == INHERENT && parameter_source(0) == INHERENT
    @test parameter_source(LAST_PARAMETER) & (INHERENT | OPAQUE) == 0 && parameter_source(LAST_PARAMETER) << 1 == OPAQUE
    # Targets and effects copy doubt in every round.
    @test sizeof(Doubt) == 4
    @test (level_of(NO_DOUBT), level_of(sourced(2)), level_of(BLIND_DOUBT)) == (Level.none, Level.code, Level.blind)
    @test sources_of(BLIND_DOUBT) == 0 && sources_of(NO_DOUBT) == 0 && sources_of(Doubt(Level.code, OPAQUE)) == OPAQUE
    @test_throws ArgumentError Doubt(Level.code, BLIND)
    @test_throws ArgumentError Doubt(Level.code, Sources(0))
    @test_throws ArgumentError Doubt(Level.none, OPAQUE)
    @test stronger(Effect(sourced(2), 3, ""), Effect(sourced(4), 2, "")) == Effect(sourced(2, 4), 2, "")
    @test stronger(Effect(CODE_DOUBT, 3, ""), Effect(CODE_DOUBT, 2, "")) == Effect(CODE_DOUBT, 2, "")
    @test stronger(Effect(NO_DOUBT, 3, ""), Effect(CODE_DOUBT, 2, "")) == Effect(NO_DOUBT, 3, "")
    @test same(empty_summary(), empty_summary()) && !same(empty_summary(), open_summary(1, "cause"))
    opened = open_summary(2, "cause")
    @test opened.writes[memory((parameter(2), true))] == Effect(BLIND_DOUBT, 0, "cause") && opened.result[Node.Outside()] == BLIND_DOUBT
    cache = IdDict{Any, Bool}()
    @test !referent!(cache, Union{}) && referent!(cache, Union{Int, Vector{Int}}) && !referent!(cache, Union{Int, Symbol})
    @test referent!(cache, AbstractVector) && !referent!(cache, Type{Int}) && referent!(cache, Ptr{Int})
    @test !referent!(cache, Tuple{Int, Symbol}) && referent!(cache, Tuple{Int, Vector{Int}}) && !referent!(cache, Module)
    # Tuple of unknown length points as its element types do; bare `Vararg` takes any element.
    @test !referent!(cache, Tuple{Vararg{Int}}) && !referent!(cache, Tuple{Symbol, Vararg{Union{Int, Float64}}}) && referent!(cache, Tuple{Vararg{Vector{Int}}})
    @test referent!(cache, Tuple{Int, Vararg}) && referent!(cache, Tuple{Vararg{Integer}})
    @test field_step(Tuple{Int}, :a) === nothing && field_step(Tuple{Int}, 1) == Step.Position(1)
    # Array stand-in and `Array` families name fields as members do; code struct family keeps `Position`.
    @test field_step(Base.RefValue{Int}, 1) == Step.Field(:x) && field_step(Base.RefValue, 1) == Step.Position(1)
    @test field_step(ArrayStandIn{<:Any, 1}, 1) == Step.Field(:data) && field_step(Vector, 2) == Step.Field(:size)
    @test field_step(Union{ArrayStandIn{T, 1}, DenseStandIn{T, 1}} where {T}, 1) == Step.Position(1)
    @test field_step(AbstractVector, 1) == Step.Position(1) && field_step(NTuple{N, Int} where {N}, 1) == Step.Position(1)
    @test field_step(Base.RefValue{Int}, 1.0) === nothing
    @test backing_field(Vector{Int}, :ref) && !backing_field(Vector{Int}, :nope) && !backing_field(Vector{Int}, 9)
    @test !backing_field(Tuple{Memory{Int}}, 1) && !backing_field(Vector{Int}, :size)
    @test backing_field(Vector, :ref) && !backing_field(AbstractVector, :ref) && !backing_field(NamedTuple{(:ref,)}, :ref)
    @test !backing_field(Base.RefValue, :x)
    @test slot_type(Base.RefValue{Int}, nothing) == Any && slot_type(Base.RefValue{Int}, Some{Any}(:x)) == Int
    @test slot_type(Base.RefValue{Int}, Some{Any}(:nope)) == Any && slot_type(AbstractVector, Some{Any}(1)) == Any
    @test slot_type(ArrayStandIn{<:Any, 1}, Some{Any}(:data)) == Vector && slot_type(Base.RefValue{<:Real}, Some{Any}(:x)) == Any
    @test element_type(Ptr{Int}) == Int && element_type(Vector{Int}) == Any && element_type(Union{Int, Ptr{Int}}) == Any
    @test element_type(MemoryRef{Vector{Int}}) == Vector{Int}
    @test root_of(Place.Deep(Root.Elsewhere())) == Root.Elsewhere()
    # Equality by matching: each variant equals copy of itself and no other value; `isequal` agrees with `==`.
    at = Place.At(Root.Parameter(2), Step.Type[Step.Field(:a)])
    mutable_steps = Step.Type[Step.Field(:a)]
    stable = Place.At(Root.Parameter(2), mutable_steps)
    empty!(mutable_steps)
    @test stable == at && all(seed -> hash(stable, seed) == hash(at, seed), UInt[0, 1, typemax(UInt)])
    @test get(Dict(stable => 7), at, 0) == 7
    path = Facts.PlaceSteps(Step.Type[Step.Field(:a)])
    @test_throws ArgumentError path.steps
    @test_throws ArgumentError path.fingerprint
    @test_throws Base.CanonicalIndexError setindex!(path, Step.Field(:b), 1)
    # Extended path equals and hashes as path built at once.
    extended = Facts.PlaceSteps(Facts.PlaceSteps(path, Step.Element()), Step.Position(1))
    whole = Facts.PlaceSteps(Step.Type[Step.Field(:a), Step.Element(), Step.Position(1)])
    @test extended == whole && hash(Place.At(Root.Parameter(2), extended)) == hash(Place.At(Root.Parameter(2), whole)) && length(path) == 1
    @test Place.At(Root.Elsewhere(), Facts.NO_STEPS) == Place.At(Root.Elsewhere(), Step.Type[])
    groups = (
        [Step.Field(:a), Step.Field(:b), Step.Position(1), Step.Element()],
        [Root.Parameter(2), Root.Global(GlobalRef(Base, :stdout)), Root.Elsewhere()],
        [at, Place.At(Root.Parameter(2), Step.Type[Step.Element()]), Place.At(Root.Parameter(3), Step.Type[Step.Field(:a)]), Place.Deep(Root.Parameter(2))],
        [Origin.Caller(at), Origin.Allocation(3), Origin.Allocation(4), Origin.Unknown()],
        [Node.Placed(at), Node.Fresh(3), Node.Outside()],
    )
    for group in groups
        @test [first == deepcopy(second) for first in group, second in group] == [i == j for i in eachindex(group), j in eachindex(group)]
        @test [isequal(first, deepcopy(second)) for first in group, second in group] == [i == j for i in eachindex(group), j in eachindex(group)]
    end
    targets = Targets(Origin.Unknown() => CODE_DOUBT)
    @test !add!(targets, Origin.Unknown(), BLIND_DOUBT) && add!(targets, Origin.Unknown(), NO_DOUBT)
    table = Dict{Tuple{Origin.Type, Bool, EffectKind.T}, Effect}()
    access!(table, Targets(Origin.Allocation(1) => BLIND_DOUBT), false, Effect(BLIND_DOUBT, 4, "cause"), EffectKind.memory)
    @test table[(Origin.Allocation(1), false, EffectKind.memory)] == Effect(BLIND_DOUBT, 4, "cause")
    run = start_run(nothing, Module[])
    instance = only(something(dispatch(Any[typeof(fill_one!), Vector{Int}], run.world, 1)))
    solve!(run, [(instance, Pair{Int, Any}[])])
    code = run.codes[(instance, Pair{Int, Any}[])]
    @test constant(code.ir, GlobalRef(Base, :nothing)) == Some(nothing)
    @test operand_type(code.ir, Operand.Part(Core.Argument(2), 1)) == MemoryRef{Int}
    @test value_type(code.ir, Expr(:call, GlobalRef(Core, :tuple), QuoteNode(:jl_n_threads), "libjulia-internal")) == Tuple{Symbol, String}
    flow = start_flow(code.ir, code.outcomes, code.message, false, false, Sources[], false, false, run.work_limit)
    @test_throws ArgumentError statement!(flow, 1, Expr(:unknown_head), Callees(Vector{Variant}[], Dict{Variant, Slot}(), Set{Variant}()))
    @test_throws ArgumentError statement!(flow, 1, QuoteNode(:literal), Callees(Vector{Variant}[], Dict{Variant, Slot}(), Set{Variant}()))
    # `copy` result: `Array` backed by fresh `Memory` that holds caller elements merges exactly.
    element, array, buffer = Node.Placed(Place.At(Root.Parameter(2), Step.Type[Step.Element()])), Node.Fresh(12), Node.Fresh(5)
    copied = fresh_summary(2, Edges((buffer, Step.Element()) => Nodes(element => NO_DOUBT)), Holds(array => Nodes(buffer => NO_DOUBT)), Holds())
    @test merges_exactly(copied) && map_node!(flow, array, CallSite(Targets[], Sources[], 7, copied)) == Targets(Origin.Allocation(7) => NO_DOUBT)
    # Two fresh nodes fill one slot: merged load could give either caller object.
    other = Node.Placed(Place.At(Root.Parameter(3), Step.Type[Step.Element()]))
    clashing = fresh_summary(2, Edges((buffer, Step.Element()) => Nodes(element => NO_DOUBT), (array, Step.Element()) => Nodes(other => NO_DOUBT)), copied.backing, Holds())
    @test !merges_exactly(clashing) && map_node!(flow, Node.Fresh(4), CallSite(Targets[], Sources[], 7, clashing)) == Targets(Origin.Allocation(7) => BLIND_DOUBT)
    # Unknown slot or backing outside fresh nodes reaches every slot: exact only when no other fresh node stores.
    spread = Holds(array => Nodes(other => NO_DOUBT))
    @test !merges_exactly(fresh_summary(2, copied.edges, copied.backing, spread)) && merges_exactly(fresh_summary(2, Edges((array, Step.Element()) => Nodes(element => NO_DOUBT)), Holds(buffer => Nodes(array => NO_DOUBT)), spread))
    @test !merges_exactly(fresh_summary(2, copied.edges, Holds(array => Nodes(other => NO_DOUBT, buffer => NO_DOUBT)), Holds())) && !merges_exactly(fresh_summary(2, Edges(), copied.backing, Holds(array => Nodes(other => NO_DOUBT), buffer => Nodes(element => NO_DOUBT))))
    # Stores of caller objects only leave merge of one object exact.
    held = Edges((element, Step.Element()) => Nodes(buffer => NO_DOUBT), (other, Step.Element()) => Nodes(array => NO_DOUBT))
    @test merges_exactly(fresh_summary(2, held, copied.backing, Holds()))
    # Merged object of inner call backs itself: still one object (`vect` result).
    @test merges_exactly(fresh_summary(1, Edges((array, Step.Element()) => Nodes(element => NO_DOUBT)), Holds(array => Nodes(array => NO_DOUBT)), Holds()))
    # Independent objects: caller store into one would show in other (`(Vector{Any}(), Vector{Any}())`).
    @test !merges_exactly(fresh_summary(2, held, Holds(), Holds())) && !merges_exactly(fresh_summary(4, Edges(), Holds(array => Nodes(buffer => NO_DOUBT), Node.Fresh(1) => Nodes(Node.Fresh(2) => NO_DOUBT)), Holds()))
    # Site maps every fresh node to one shared allocation; outside node maps to unknown object at node doubt.
    fresh_site = CallSite(Targets[], Sources[], 7, fresh_summary(1))
    @test map_node!(flow, Node.Fresh(1), fresh_site) === map_node!(flow, Node.Fresh(2), fresh_site)
    @test map_nodes!(flow, Nodes(Node.Outside() => BLIND_DOUBT, Node.Fresh(1) => NO_DOUBT), fresh_site) == Targets(Origin.Unknown() => BLIND_DOUBT, Origin.Allocation(7) => NO_DOUBT)
    @test_throws ArgumentError map_node!(flow, Node.Fresh(1), CallSite(Targets[], Sources[], 7, fresh_summary(0)))
    # Objects without fresh origin hold nothing beneath them: result is same table.
    plain = Targets(Origin.Caller(parameter(2)) => NO_DOUBT)
    @test beneath(flow, plain) === plain
    # Chain through fresh object raises doubt; direct chain with less doubt wins (`least`), also for type sources.
    holder = Targets(Origin.Allocation(12) => CODE_DOUBT)
    store!(flow, Targets(Origin.Allocation(12) => NO_DOUBT), Step.Field(:x), Targets(Origin.Caller(parameter(3)) => NO_DOUBT, Origin.Unknown() => sourced(4)))
    @test beneath(flow, holder) == Targets(Origin.Allocation(12) => CODE_DOUBT, Origin.Caller(parameter(3)) => CODE_DOUBT, Origin.Unknown() => Doubt(Level.code, INHERENT | parameter_source(4)))
    direct = Targets(Origin.Allocation(12) => NO_DOUBT, Origin.Unknown() => NO_DOUBT)
    @test beneath(flow, direct) == Targets(Origin.Allocation(12) => NO_DOUBT, Origin.Caller(parameter(3)) => NO_DOUBT, Origin.Unknown() => NO_DOUBT)
    @test type_sources(flow, direct, Sources(0)) == parameter_source(3)
    @test type_sources(flow, holder, Sources(0)) == INHERENT | parameter_source(3) | parameter_source(4)
    # Chain with less doubt found after visit of fresh object still reaches its contents: every visit order agrees.
    for (late, early) in ((20, 21), (21, 20))
        chained = start_flow(code.ir, code.outcomes, code.message, false, false, Sources[], false, false, run.work_limit)
        store!(chained, Targets(Origin.Allocation(early) => NO_DOUBT), Step.Field(:y), Targets(Origin.Allocation(late) => NO_DOUBT))
        store!(chained, Targets(Origin.Allocation(late) => NO_DOUBT), Step.Field(:y), Targets(Origin.Caller(parameter(5)) => NO_DOUBT))
        @test beneath(chained, Targets(Origin.Allocation(late) => CODE_DOUBT, Origin.Allocation(early) => NO_DOUBT))[Origin.Caller(parameter(5))] == NO_DOUBT
    end
    # Outside object keeps doubt of its chain, at least `code`: blind store stays blind; sources join. Each link is work.
    outside = start_flow(code.ir, code.outcomes, code.message, false, false, Sources[], false, false, run.work_limit)
    store!(outside, unknown(NO_DOUBT), Step.Field(:y), Targets(Origin.Caller(parameter(2)) => BLIND_DOUBT, Origin.Allocation(20) => NO_DOUBT))
    store!(outside, Targets(Origin.Allocation(20) => NO_DOUBT), Step.Field(:z), Targets(Origin.Caller(parameter(3)) => sourced(4)))
    work = outside.work
    sourced_code = Doubt(Level.code, INHERENT | parameter_source(4))
    @test outside_targets!(outside) == Targets(
        Origin.Unknown() => NO_DOUBT, Origin.Allocation(20) => CODE_DOUBT,
        Origin.Caller(parameter(2)) => BLIND_DOUBT, Origin.Caller(Place.Deep(Root.Parameter(2))) => BLIND_DOUBT,
        Origin.Caller(parameter(3)) => sourced_code, Origin.Caller(Place.Deep(Root.Parameter(3))) => sourced_code,
    )
    @test outside.work == work + 3
    # Flow past limit stops walk: round is partial, so summary opens with `BUDGET` cause.
    spent = start_flow(code.ir, code.outcomes, code.message, false, false, Sources[], false, false, 0)
    store!(spent, unknown(NO_DOUBT), Step.Field(:y), Targets(Origin.Allocation(20) => NO_DOUBT))
    @test over_budget(spent) && outside_targets!(spent) == unknown(NO_DOUBT)
    # Callee `deep` write changes argument; object in slot of fresh argument may stay unchanged: blind.
    @test deep(flow, Targets(Origin.Caller(parameter(2)) => NO_DOUBT)) == Targets(Origin.Caller(Place.Deep(Root.Parameter(2))) => NO_DOUBT)
    wrapper = Targets(Origin.Allocation(9) => NO_DOUBT)
    store!(flow, wrapper, Step.Field(:x), Targets(Origin.Caller(parameter(3)) => NO_DOUBT))
    @test deep(flow, wrapper) == Targets(Origin.Allocation(9) => NO_DOUBT, Origin.Caller(Place.Deep(Root.Parameter(3))) => BLIND_DOUBT)
    # Argument inside other argument keeps its own doubt: callee writes it through its own place.
    both = Targets(Origin.Allocation(9) => NO_DOUBT, Origin.Caller(parameter(3)) => NO_DOUBT)
    @test deep(flow, both) == Targets(Origin.Allocation(9) => NO_DOUBT, Origin.Caller(Place.Deep(Root.Parameter(3))) => NO_DOUBT)
    # Path follows declared field types: recursive type, third abstract step in a row, and step cap collapse it.
    at(name::Symbol)::Root.Type = Root.Global(GlobalRef(@__MODULE__, name))
    field_x, link_next = Step.Field(:x), Step.Field(:next)
    @test exact_path(code.ir, at(:NESTED), Step.Type[Step.Field(:chain), link_next, Step.Field(:box), Step.Field(:value)])
    @test !exact_path(code.ir, at(:LOOP), Step.Type[link_next]) && extend(code.ir, Place.At(at(:LOOP), Step.Type[]), link_next) == Place.Deep(at(:LOOP))
    @test exact_path(code.ir, at(:ANY_REF), Step.Type[field_x, Step.Field(:a)]) && !exact_path(code.ir, at(:ANY_REF), Step.Type[field_x, Step.Field(:a), Step.Field(:b)])
    @test exact_path(code.ir, at(:NESTED_TUPLE), fill(Step.Position(1), PATH_DEPTH)) && !exact_path(code.ir, at(:NESTED_TUPLE), fill(Step.Position(1), PATH_DEPTH + 1))
    @test extend(code.ir, Place.Deep(at(:LOOP)), link_next) == Place.Deep(at(:LOOP))
    # Bits element and field that concrete type lacks hold no caller object; `Any` field can.
    caller(root::Root.Type, steps::Step.Type...)::Targets = Targets(Origin.Caller(Place.At(root, Step.Type[steps...])) => NO_DOUBT)
    @test isempty(load!(flow, caller(at(:BYTES)), Step.Element())) && isempty(load!(flow, caller(at(:NESTED)), Step.Field(:missing)))
    @test isempty(load!(flow, caller(at(:BYTES), Step.Element()), Step.Field(:x))) && load!(flow, caller(at(:ANY_REF)), field_x) == caller(at(:ANY_REF), field_x)
    @test load!(flow, caller(at(:NESTED)), Step.Position(1)) == caller(at(:NESTED), Step.Position(1)) && isempty(load!(flow, caller(at(:NESTED)), Step.Position(2)))
    # Slot targets found before heap grows go stale: load after store sees new slot and backing contents.
    box, backed = Targets(Origin.Allocation(5) => NO_DOUBT), Targets(Origin.Allocation(6) => NO_DOUBT)
    @test isempty(load!(flow, box, Step.Field(:y))) && isempty(load!(flow, box, Step.Element()))
    store!(flow, box, Step.Field(:y), Targets(Origin.Caller(parameter(2)) => NO_DOUBT))
    @test load!(flow, box, Step.Field(:y)) == Targets(Origin.Caller(parameter(2)) => NO_DOUBT)
    store_backing!(flow, box, Targets(Origin.Allocation(6) => CODE_DOUBT))
    store!(flow, backed, Step.Element(), Targets(Origin.Unknown() => NO_DOUBT))
    @test load!(flow, box, Step.Element()) == Targets(Origin.Unknown() => CODE_DOUBT)
    # Blind chain and exact chain reach one memory; roles swap, so one case visits blind chain first. Least doubt wins.
    holder, element = Origin.Allocation(33), Targets(Origin.Allocation(32) => NO_DOUBT)
    for (detour, memory) in ((Origin.Allocation(30), Origin.Allocation(31)), (Origin.Allocation(31), Origin.Allocation(30)))
        flow.backing[holder] = Targets(detour => BLIND_DOUBT, memory => NO_DOUBT)
        flow.backing[detour], flow.backing[memory] = Targets(memory => NO_DOUBT), Targets()
        flow.heap[detour], flow.heap[memory] = Dict{Step.Type, Targets}(), Dict{Step.Type, Targets}(Step.Element() => element)
        for origin in (holder, detour, memory)
            Summaries.invalidate!(flow, (origin, nothing, true))
            Summaries.invalidate!(flow, (origin, Step.Element(), false))
        end
        @test load!(flow, Targets(holder => NO_DOUBT), Step.Element()) == element
        @test load_any(flow, Targets(detour => BLIND_DOUBT, memory => NO_DOUBT)) == element
    end
    # A call with many stores reuses traces of other slots on the same object.
    many = start_flow(code.ir, code.outcomes, code.message, false, false, Sources[], false, false, run.work_limit)
    summary = empty_summary()
    prefix = Step.Field(:chain)
    root = global_place(@__MODULE__, :NESTED)
    for index in 1:40
        place = Place.At(Root.Global(GlobalRef(@__MODULE__, :NESTED)), Step.Type[prefix, Step.Position(index)])
        summary.edges[(Node.Placed(root), Step.Position(index))] = Nodes(Node.Placed(place) => NO_DOUBT)
    end
    Summaries.apply_stores!(many, CallSite(Targets[], Sources[], 1, fresh_summary(0)), summary)
    @test haskey(many.follows, (Origin.Caller(root), prefix))
    @test length(many.follows) >= 40
    # This fixture executes 41 traces; allow headroom for changes in path handling.
    @test many.traces <= 60
    # A backing-chain mutation invalidates every trace that reaches the changed origin.
    chain = start_flow(code.ir, code.outcomes, code.message, false, false, Sources[], false, false, run.work_limit)
    first_memory, second_memory = Targets(Origin.Allocation(101) => NO_DOUBT), Targets(Origin.Allocation(102) => NO_DOUBT)
    store_backing!(chain, first_memory, second_memory)
    @test isempty(load!(chain, first_memory, Step.Element()))
    store!(chain, second_memory, Step.Element(), Targets(Origin.Unknown() => NO_DOUBT))
    @test load!(chain, first_memory, Step.Element()) == Targets(Origin.Unknown() => NO_DOUBT)
    spread = start_flow(code.ir, code.outcomes, code.message, false, false, Sources[], false, false, run.work_limit)
    @test isempty(load!(spread, first_memory, Step.Field(:x))) && isempty(load!(spread, first_memory, Step.Field(:y)))
    store!(spread, first_memory, nothing, Targets(Origin.Unknown() => NO_DOUBT))
    @test load!(spread, first_memory, Step.Field(:x)) == Targets(Origin.Unknown() => NO_DOUBT)
    @test load!(spread, first_memory, Step.Field(:y)) == Targets(Origin.Unknown() => NO_DOUBT)
    # A retained trace still charges the work of a global cache flush.
    limited = start_flow(code.ir, code.outcomes, code.message, false, false, Sources[], false, false, 2)
    @test isempty(load!(limited, first_memory, Step.Element()))
    store!(limited, second_memory, Step.Element(), Targets(Origin.Unknown() => NO_DOUBT))
    @test isempty(load!(limited, first_memory, Step.Element()))
    @test limited.traces == 1 && limited.work == 3 && over_budget(limited)
    # Long traces stay indexed until the flow membership budget fills.
    long = start_flow(code.ir, code.outcomes, code.message, false, false, Sources[], false, false, run.work_limit)
    memories = [Targets(Origin.Allocation(index) => NO_DOUBT) for index in 1001:2000]
    for index in 1:(length(memories) - 1)
        store_backing!(long, memories[index], memories[index + 1])
    end
    @test all(isempty(load!(long, memory, Step.Element())) for memory in memories)
    memberships = sum(length, values(long.dependents); init = 0)
    @test memberships == long.memberships && memberships <= Summaries.TRACE_MEMBERSHIP_LIMIT
    @test memberships > 6240 && !isempty(long.coarse)
    @test long.traces == 1000
    @test isempty(load!(long, first(memories), Step.Element())) && long.traces == 1000
    store!(long, Targets(Origin.Allocation(2001) => NO_DOUBT), Step.Element(), Targets(Origin.Unknown() => NO_DOUBT))
    @test isempty(long.coarse) && haskey(long.follows, (Origin.Allocation(1001), Step.Element()))
    @test isempty(load!(long, first(memories), Step.Element())) && long.traces == 1000
    store!(long, last(memories), Step.Element(), Targets(Origin.Unknown() => NO_DOUBT))
    expected = Summaries.trace!(long, Origin.Allocation(1001), Step.Element()).targets
    @test load!(long, first(memories), Step.Element()) == expected == Targets(Origin.Unknown() => NO_DOUBT)
    @test long.memberships == sum(length, values(long.dependents); init = 0)
    # Type sources: parameter of caller place, sources of chain; global and merge of fresh objects are doubt in code.
    held_global = Origin.Caller(global_place(@__MODULE__, :HOLDER))
    none = Sources(0)
    @test type_sources(flow, Targets(Origin.Unknown() => sourced(3)), none) == parameter_source(3)
    @test type_sources(flow, Targets(held_global => NO_DOUBT, Origin.Caller(parameter(2)) => NO_DOUBT), none) == INHERENT | parameter_source(2)
    flow.heap[Origin.Allocation(1)] = Dict(Step.Field(:x) => Targets(Origin.Caller(parameter(2)) => NO_DOUBT))
    @test type_sources(flow, Targets(Origin.Allocation(1) => NO_DOUBT), none) == parameter_source(2)
    @test type_sources(flow, Targets(Origin.Allocation(1) => NO_DOUBT, Origin.Allocation(2) => NO_DOUBT), parameter_source(3)) == INHERENT
    # Derived sources stand without object; with no source at all, doubt is in code.
    @test type_sources(flow, Targets(), parameter_source(3)) == parameter_source(3) && type_sources(flow, Targets(), none) == INHERENT
    # Objects decide when they give source: derived sources stand in only for value without object source.
    @test type_sources(flow, Targets(Origin.Caller(parameter(2)) => NO_DOUBT), parameter_source(3)) == parameter_source(2)
    # Growth of derived sources alone starts another round; same sources start none.
    flow.changed = false
    derive!(flow, 1, parameter_source(2))
    @test flow.changed && flow.derived[1] == parameter_source(2)
    flow.changed = false
    derive!(flow, 1, parameter_source(2))
    @test !flow.changed
    # Static parameter takes source of each parameter whose declared type holds it, vararg included.
    @test static_sources(only(methods(static_both))) == [parameter_source(2) | parameter_source(3)]
    @test static_sources(only(methods(static_pair))) == [parameter_source(2), parameter_source(3)] && isempty(static_sources(only(methods(fill_one!))))
    # Callee parameter source becomes type sources of argument, derived ones too; parameter without argument is doubt in code.
    site = CallSite([Targets(), Targets(Origin.Caller(parameter(4)) => NO_DOUBT), Targets()], Sources[none, none, parameter_source(5)], 7, fresh_summary(0))
    @test caller_doubt!(flow, site, sourced(1)) == CODE_DOUBT && caller_doubt!(flow, site, sourced(2)) == sourced(4)
    @test caller_doubt!(flow, site, sourced(3)) == sourced(5) && caller_doubt!(flow, site, sourced(4)) == CODE_DOUBT
    # Source past unit arguments is doubt in code.
    @test source_provenance(parameter_source(3), [Provenance.code, Provenance.opaque]) == Provenance.code
    # Spread part as callee: `MemoryRef` has no call method, so call throws.
    @test isa_variant(resolve(code.ir, Operand.Type[Operand.Part(Core.Argument(2), 1)], run.world, 1), Outcome.Dead)
    typed = only(unit for unit in UNITS.typed if unit.site.method.name == :add)
    @test cause_span(typed, code, 0) == typed.site.span
    shared, partial = (Origin.Allocation(1), false, EffectKind.memory), (Origin.Allocation(2), false, EffectKind.memory)
    joined = Dict(partial => Effect(NO_DOUBT, 1, ""))
    # Blind spot of one member leaves exact write of other `possible`; blind in every member stays blind.
    join_accesses!(joined, [Dict(shared => Effect(NO_DOUBT, 5, ""), partial => Effect(CODE_DOUBT, 5, "")), Dict(shared => Effect(BLIND_DOUBT, 4, "alias"))], CODE_DOUBT)
    @test joined == Dict(shared => Effect(CODE_DOUBT, 5, ""), partial => Effect(NO_DOUBT, 1, ""))
    joined = Dict{Tuple{Origin.Type, Bool, EffectKind.T}, Effect}()
    join_accesses!(joined, [Dict(shared => Effect(BLIND_DOUBT, 5, "alias")), Dict(shared => Effect(BLIND_DOUBT, 4, "alias")), Dict{Tuple{Origin.Type, Bool, EffectKind.T}, Effect}()], CODE_DOUBT)
    @test joined == Dict(shared => Effect(BLIND_DOUBT, 5, "alias"))
    joined = Dict{Tuple{Origin.Type, Bool, EffectKind.T}, Effect}()
    join_accesses!(joined, [Dict(partial => Effect(NO_DOUBT, 5, "")), Dict{Tuple{Origin.Type, Bool, EffectKind.T}, Effect}()], sourced(4))
    @test joined == Dict(partial => Effect(sourced(4), 5, ""))
    # Members with `code` doubt from different sources: join keeps sources of all.
    joined = Dict{Tuple{Origin.Type, Bool, EffectKind.T}, Effect}()
    join_accesses!(joined, [Dict(shared => Effect(sourced(2), 5, "")), Dict(shared => Effect(sourced(3), 6, ""))], CODE_DOUBT)
    @test joined == Dict(shared => Effect(sourced(2, 3), 5, ""))
    # Join must reach every call native inference resolves.
    @test JOIN_LIMIT >= Summaries.CC.InferenceParams().max_methods
    world = Base.get_world_counter()
    @test length(something(dispatch(Any[typeof(three_way), Any], world, JOIN_LIMIT))) == JOIN_LIMIT
    @test isnothing(dispatch(Any[typeof(four_way), Any], world, JOIN_LIMIT))
    # Package code joins; library code keeps run-time dispatch open.
    @test isnothing(dispatch(Any[typeof(three_way), Any], world, 1))
    package_run = start_run(nothing, [@__MODULE__])
    @test join_limit(package_run, only(something(dispatch(Any[typeof(three_way), Int], world, 1)))) == JOIN_LIMIT
    @test join_limit(package_run, only(something(dispatch(Any[typeof(push!), Vector{Int}, Int], world, 1)))) == 1
    possible_first = Access(parameter(2), false, EffectKind.memory, Confidence.possible, false, typed.site.span)
    @test worst([possible_first, Access(parameter(2), false, EffectKind.memory, Confidence.definite, false, typed.site.span)])[1].confidence == Confidence.definite
    # Kinds stay apart: definite IO write never hides `possible` memory write.
    @test length(worst([possible_first, Access(parameter(2), false, EffectKind.io, Confidence.definite, false, typed.site.span)])) == 2
    # Callback mark stays apart too: definite write of callable argument never hides `possible` own write.
    @test length(worst([possible_first, Access(parameter(2), false, EffectKind.memory, Confidence.definite, true, typed.site.span)])) == 2
end

"""Whether `first` and `second` hold same state: same type, and same fields and elements, deep."""
function same_state(first::Any, second::Any)::Bool
    typeof(first) == typeof(second) || return false
    if first isa AbstractArray
        size(first) == size(second) || return false
        # Hash table memory (`IdDict`) holds unassigned slots.
        return all(index -> isassigned(first, index) == isassigned(second, index) && (!isassigned(first, index) || same_state(first[index], second[index])), eachindex(first))
    end
    type = typeof(first)
    isstructtype(type) && fieldcount(type) > 0 || return isequal(first, second)
    return all(fieldnames(type)) do name
        isdefined(first, name) == isdefined(second, name) && (!isdefined(first, name) || same_state(getfield(first, name), getfield(second, name)))
    end
end

"""Whether `found` has definite, possible or blind write whose place starts at `root`."""
covered(found::MethodVerdict, root::Root.Type)::Bool = any(access -> root_of(access.place) == root, [found.writes; found.blind_writes])

"""Globals of fixture module that methods write, as deep copies."""
globals_now()::Dict{Symbol, Any} = Dict(name => deepcopy(getglobal(CASES, name)) for name in (:COUNTER, :total, :NEST))

const INTS = Data.Integers(-2, 3)
const BOXES = map(value -> CASES.Box(value), INTS)
const VECTORS = Data.Vectors(INTS; min_size = 2, max_size = 4)
const WRAPPERS = map(box -> CASES.Wrapper(CASES.Chain(CASES.Holder(box))), BOXES)
const LOOSES = map(content -> CASES.Loose(content), Data.OneOf(BOXES, VECTORS, Data.Just("text")))
const CELLS = Data.OneOf(map(Ref, INTS), map(value -> Ref(Float64(value)), INTS))

"""Generator of argument tuples with first argument from `first` and second from `second`."""
both(first::Data.Possibility, second::Data.Possibility)::Data.Possibility = map(Tuple, Data.Pairs(first, second))

"""Fixture methods with argument generator: tuple of fresh arguments per draw."""
const CALLS = [
    (CASES.set_value!, both(BOXES, INTS)), (CASES.set_inner!, both(map(CASES.Holder, BOXES), INTS)),
    (CASES.set_deep!, both(map(box -> CASES.Chain(CASES.Holder(box)), BOXES), INTS)), (CASES.set_deeper!, both(WRAPPERS, INTS)),
    (CASES.call_deeper!, map(tuple, WRAPPERS)), (CASES.fill_first!, map(tuple, VECTORS)), (CASES.swap_first!, both(VECTORS, INTS)),
    (CASES.first_value, map(tuple, VECTORS)), (CASES.read_box, map(tuple, BOXES)), (CASES.add, both(INTS, INTS)),
    (CASES.bump!, Data.Just(())), (CASES.set_total!, map(tuple, INTS)), (CASES.read_total, Data.Just(())), (CASES.read_module, Data.Just(())),
    (CASES.fresh_sum, map(tuple, INTS)), (CASES.push_box!, both(Data.Vectors(BOXES; max_size = 2), BOXES)),
    (CASES.zero_view!, map(tuple, VECTORS)), (CASES.reset_counter!, Data.Just(())), (CASES.countdown!, both(BOXES, INTS)),
    (CASES.ping!, both(BOXES, INTS)), (CASES.pong!, both(BOXES, INTS)), (CASES.increment!, map(value -> (CASES.Counter(value),), INTS)),
    (CASES.swap_count!, both(map(CASES.Counter, INTS), INTS)), (CASES.touch!, map(tuple, Data.OneOf(BOXES, VECTORS, Data.Just("text")))),
    (CASES.poke!, map(tuple, LOOSES)), (CASES.store_pointer!, map(tuple, VECTORS)), (CASES.load_pointer, map(tuple, VECTORS)),
    (CASES.copy_box, map(tuple, BOXES)), (CASES.boxes_of, map(tuple, BOXES)), (CASES.bump_nest!, Data.Just(())), (CASES.call_nest!, Data.Just(())),
    (CASES.stamp_either!, map(tuple, CELLS)), (CASES.measure_either, map(tuple, CELLS)), (CASES.copy_into!, map(values -> (zero(values), values), VECTORS)),
    (CASES.copy_boxes!, map(boxes -> ([CASES.Box(1) for _ in boxes], boxes), Data.Vectors(BOXES; min_size = 1, max_size = 3))),
    (CASES.remember!, map(box -> (IdDict{Int, CASES.Box}(), box), BOXES)),
    (CASES.fill_pair!, map(tuple, BOXES)), (CASES.push_pair!, map(tuple, VECTORS)), (CASES.set_pair!, map(tuple, BOXES)),
    (CASES.call_setter!, both(map(CASES.Setter, BOXES), INTS)), (CASES.count_down!, map(tuple, BOXES)),
    (CASES.act_either!, both(Data.OneOf(map(CASES.Setter, BOXES), map(box -> CASES.Relay(CASES.Setter(box)), BOXES)), INTS)),
    (CASES.restart!, map(drawn -> (drawn.first, drawn.second.first, drawn.second.second), Data.Pairs(BOXES, Data.Pairs(BOXES, Data.Integers(0, 3))))),
    (CASES.pick_setter!, both(map(CASES.Setter, BOXES), INTS)),
    (CASES.read_scope, Data.Just(())), (CASES.same_box, map(tuple, BOXES)), (CASES.call_claim_bump!, Data.Just(())),
    (CASES.drop_claim_set!, map(tuple, BOXES)), (CASES.drop_block_claim!, map(tuple, BOXES)), (CASES.call_generated, map(tuple, INTS)),
]

"""Whether `to` is reachable from `from` along `successors`, in zero or more steps."""
function reaches(successors::Vector{Vector{Int}}, from::Int, to::Int)::Bool
    seen, pending = Set{Int}(), [from]
    while !isempty(pending)
        vertex = pop!(pending)
        vertex == to && return true
        vertex in seen && continue
        push!(seen, vertex)
        append!(pending, successors[vertex])
    end
    return false
end

"""Graph of `size` vertices with edge from `from` to `to` where mark is 0: one edge in four."""
graph((size, marks)::Pair{Int, Vector{Int}})::Vector{Vector{Int}} = [[to for to in 1:size if marks[8 * (from - 1) + to] == 0] for from in 1:size]

"""Graph whose vertex list starts at index 0: vertex numbers name no position of it."""
struct ZeroBased <: AbstractVector{Vector{Int}}
    successors::Vector{Vector{Int}}
end
Base.size(graph::ZeroBased) = size(graph.successors)
Base.axes(graph::ZeroBased) = (0:(length(graph.successors) - 1),)
Base.getindex(graph::ZeroBased, position::Int) = graph.successors[position + 1]

"""Graphs of 1 to 8 vertices."""
const GRAPHS = map(graph, Data.Pairs(Data.Integers(1, 8), Data.Vectors(Data.Integers(0, 3); min_size = 64, max_size = 64)))

@testset "call graph components" begin
    @test components(Vector{Int}[]) == Vector{Int}[]
    @test components([[1]]) == [[1]]
    @test components([[2], [3], Int[]]) == [[3], [2], [1]]
    @test sort.(components([[2], [1, 3], Int[]])) == [[3], [1, 2]]
    # Path of 10^5 vertices: explicit stack keeps deep call chains off native stack.
    @test length(components([[[vertex + 1] for vertex in 1:99_999]; [Int[]]])) == 100_000
    @check max_examples = 300 db = false function components_condense(successors = GRAPHS)
        found = components(successors)
        place = Dict(vertex => position for (position, component) in enumerate(found) for vertex in component)
        vertices = eachindex(successors)
        partition = sort!(reduce(vcat, found; init = Int[])) == collect(vertices)
        mutual = all(place[from] == place[to] || !(reaches(successors, from, to) && reaches(successors, to, from)) for from in vertices, to in vertices)
        apart = all(place[from] != place[to] || (reaches(successors, from, to) && reaches(successors, to, from)) for from in vertices, to in vertices)
        ordered = all(place[callee] <= place[caller] for caller in vertices for callee in successors[caller])
        partition && mutual && apart && ordered
    end
end

@testset "solve schedule" begin
    # Components of `[[2], [1, 3], []]` are `[3]` and `[1, 2]`: second calls first.
    successors = [[2], [1, 3], Int[]]
    @test component_graph(successors, components(successors)) == [Int[], [1]]
    # Narrow vertex type works: workers write own `Int` counts, so graph element type is free.
    narrow, order = Vector{Int32}[Int32[], Int32[1]], Int[]
    @test component_graph(narrow, [Int32[1], Int32[2]]) == [Int[], [1]]
    after_successors(vertex -> push!(order, vertex), narrow; workers = 1)
    @test order == [1, 2]
    # Vertex numbers count from one, so graph with other first index is rejected.
    @test_throws ArgumentError component_graph(ZeroBased([Int[], [1]]), [[1], [2]])
    # Each vertex of condensed graph runs once, after each component it calls; on one worker and on three.
    @check max_examples = 300 db = false function runs_callees_first(successors = GRAPHS, workers = Data.Integers(1, 3))
        # Atomic count per vertex: test process may run several threads.
        condensed = component_graph(successors, components(successors))
        runs = [Threads.Atomic{Int}(0) for _ in condensed]
        after_successors(vertex -> all(callee -> runs[callee][] == 1, condensed[vertex]) && Threads.atomic_add!(runs[vertex], 1), condensed; workers)
        all(count -> count[] == 1, runs)
    end
    @test_throws ArgumentError after_successors(identity, [[2], Int[]])
    @test_throws ArgumentError after_successors(identity, [Int[]]; workers = 0)
    after_successors(vertex -> error("graph has no vertex"), Vector{Int}[])
    # Failed step stops schedule: its callers never run, and error reaches caller.
    finished = Int[]
    @test_throws CompositeException after_successors(vertex -> vertex == 2 ? error("step failed") : push!(finished, vertex), [Int[], [1], [2]])
    @test finished == [1]
    # Test process may run one thread, so child process runs schedule and solve on four.
    child = `$(Base.julia_cmd()) --threads=4 --startup-file=no --project=$(Base.active_project()) $(joinpath(@__DIR__, "effects", "threaded.jl"))`
    @test read(child, String) == "threaded solve ok"
end

"""Link of synthetic call chain: each specialization stands for one instance."""
chain_link(x::Any) = x

"""Store that flag argument guards; callers pass constant flag, as `HAMT.path` copy-on-write flag."""
flag_store!(x::Vector{Int}, store::Bool) = (store && (x[1] = 0); x)
flag_off(x::Vector{Int}) = flag_store!(x, false)
flag_on(x::Vector{Int}) = flag_store!(x, true)

"""Branch that constant flag drops holds `try`: `leave` in dropped block must stay."""
function flag_try!(x::Vector{Int}, careful::Bool)
    if careful
        try
            x[1] = 0
            return x
        catch
            return x
        end
    end
    return x
end
flag_try_off(x::Vector{Int}) = flag_try!(x, false)

"""Property `:log` writes global log; other names read field, as `getproperty(::Task, ::Symbol)` does."""
mutable struct Switch
    n::Int
end
const SWITCH_LOG = Int[]
Base.getproperty(switch::Switch, name::Symbol) = name === :log ? (push!(SWITCH_LOG, 1); 0) : getfield(switch, name)
# Write keeps compiler effects from skipping summary.
bump_switch!(switch::Switch) = (switch.n += 1; nothing)
switch_log(switch::Switch) = switch.log

@testset "variant parameters" begin
    run = start_run(nothing, Module[])
    instance = only(something(dispatch(Any[typeof(fill_one!), Vector{Int}], run.world, 1)))
    solve!(run, [(instance, Pair{Int, Any}[])])
    ir = run.codes[(instance, Pair{Int, Any}[])].ir
    # Chain of 10^5 calls: explicit stack keeps deep call chains off native stack.
    links = [Summaries.CC.specialize_method(only(methods(chain_link)), Tuple{typeof(chain_link), Val{position}}, Core.svec()) for position in 1:100_000]
    argument = Operand.Value(Core.Argument(2))
    for (position, link) in enumerate(links)
        outcome = position == length(links) ? Outcome.Builtin(Core.getfield, [argument, Operand.Value(QuoteNode(:a))]) : Outcome.Dispatch([links[position + 1]], [Operand.Value(chain_link), argument])
        run.bodies[link] = Body(ir, Int[], Union{Nothing, Outcome.Type}[outcome], [false], [false], false, false)
    end
    @test variant_parameters!(run, first(links)) == Set([2])
    # Branch condition: constant flag drops unreached store, as Julia inference does; unknown flag keeps it.
    flagged = only(something(dispatch(Any[typeof(flag_store!), Vector{Int}, Bool], run.world, 1)))
    # Position 2 reaches object operand of `getfield` in `setindex!`.
    @test variant_parameters!(run, flagged) == Set([2, 3])
    @test isempty(summary_of(flag_off, Vector{Int}).writes)
    @test doubts(summary_of(flag_on, Vector{Int}).writes) == Dict(top(2) => NO_DOUBT)
    @test haskey(doubts(summary_of(flag_store!, Vector{Int}, Bool).writes), top(2))
    # Dropped branch keeps its try region balanced (`Base.rm` with `recursive = false` crashed release balance).
    @test isempty(summary_of(flag_try_off, Vector{Int}).writes)
    # `===` of constant name: variant for field `n` drops branch that writes log; variant for `:log` keeps it.
    @test doubts(summary_of(bump_switch!, Switch).writes) == Dict(top(2) => NO_DOUBT)
    @test Root.Global(GlobalRef(@__MODULE__, :SWITCH_LOG)) in Set(root_of(place) for (place, _, _) in keys(summary_of(switch_log, Switch).writes))
end

"""Wrapper whose type grows at each recursion step."""
struct Layer{T}
    inner::T
end

"""Steps of recursive fixtures: write keeps compiler from proving them empty, so engine reaches their callees."""
const STEPS = Ref(0)

deepen(x::Any, n::Int) = (STEPS[] += 1; n == 0 ? x : deepen(Layer(x), n - 1))
deepen_odd(x::Any, n::Int) = (STEPS[] += 1; n == 0 ? x : deepen_even(Layer(x), n - 1))
deepen_even(x::Any, n::Int) = (STEPS[] += 1; n == 0 ? x : deepen_odd(Layer(x), n - 1))

"""Steps layer content `Int`, `Float64`, `Float32`: signature changes at each step but never grows."""
retag(x::Any, n::Int) = (STEPS[] += 1; n == 0 ? x : retag(Layer(narrow(x.inner)), n - 1))
narrow(x::Int) = Float64(x)
narrow(x::Float64) = Float32(x)
narrow(x::Float32) = x

"""Shells whose abstract content makes recursive call join both `peel` methods."""
abstract type Shell end
struct OuterShell <: Shell
    inner::Shell
end
struct InnerShell <: Shell
    inner::Shell
end

peel(f::Any, shell::OuterShell) = (STEPS[] += 1; peel(f ∘ identity, shell.inner))
peel(f::Any, shell::InnerShell) = (STEPS[] += 1; peel(f ∘ identity, shell.inner))

@testset "recursion limit" begin
    # Signature grows each step (`ComposedFunction` in LinearAlgebra `_any`): after one or two steps it widens.
    # `retag` changes without growth: self-recursion compares with caller, so `Layer{Float32}` stays exact.
    cases = ((deepen, (Int, Int), (:deepen,), 3, Tuple{typeof(deepen), Layer, Int}), (deepen_odd, (Int, Int), (:deepen_odd, :deepen_even), 5, Tuple{typeof(deepen_odd), Layer, Int}), (peel, (typeof(sin), OuterShell), (:peel,), 5, Tuple{typeof(peel), ComposedFunction, InnerShell}), (retag, (Layer{Int}, Int), (:retag,), 3, Tuple{typeof(retag), Layer{Float32}, Int}))
    for (f, types, names, total, expected) in cases
        run = start_run(nothing, [@__MODULE__])
        root = (only(something(dispatch(Any[typeof(f), types...], run.world, 1))), Pair{Int, Any}[])
        solve!(run, [root])
        reached = filter(instance -> instance.def.name in names, collect(keys(run.bodies)))
        @test length(reached) == total
        @test any(instance -> instance.specTypes == expected, reached)
    end
    @test journal_key(only(something(dispatch(Any[typeof(push!), Vector{Int}, Int], Base.get_world_counter(), 1)))) == "effects\nTuple{typeof(push!), Array{Int64, 1}, Int64}"
end

const DOUBTS = Data.SampledFrom([NO_DOUBT, CODE_DOUBT, sourced(2), sourced(3), BLIND_DOUBT])
const EFFECTS = map(((doubt, cause),) -> Effect(doubt, cause, doubt == BLIND_DOUBT ? "alias" : ""), Data.Pairs(DOUBTS, Data.Integers(1, 2)))
const ACCESSES = Data.Dicts(Data.SampledFrom([(parameter(2), false, EffectKind.memory), (parameter(2), true, EffectKind.memory), (parameter(3), false, EffectKind.io)]), EFFECTS; max_size = 3)
const NODES = Data.Dicts(Data.SampledFrom([Node.Placed(parameter(2)), Node.Fresh(1), Node.Outside()]), DOUBTS; max_size = 3)

"""Whether `first` doubts at most as `second` does: lower level, or same level with every source of `second`."""
at_most(first::Doubt, second::Doubt)::Bool = level_of(first) < level_of(second) || level_of(first) == level_of(second) && sources_of(first) & sources_of(second) == sources_of(second)

"""Summaries over two parameters: few places, nodes and causes, so draws overlap."""
const SUMMARIES = @composed function summaries(writes = ACCESSES, reads = ACCESSES, held = NODES, result = NODES, fresh = Data.Integers(0, 2), closed = Data.Booleans(), cut = Data.Booleans())
    edges = isempty(held) ? Edges() : Edges((Node.Placed(parameter(2)), Step.Element()) => held)
    bound = isempty(held) ? Dict{GlobalRef, Nodes}() : Dict(GlobalRef(Main, :slot) => held)
    return Summary(writes, reads, edges, Holds(Node.Fresh(1) => held), Holds(), bound, Set{Callback}(), result, fresh, closed, cut, HoldCounts(), HoldCounts(), Dict{Tuple{Node.Type, Resource.T}, Unguarded}())
end

@testset "call cycle widening" begin
    key, single = (Node.Placed(parameter(2)), Resource.lock), HoldCount(1, Level.none, 3, "")
    old_holds, old_unguarded = HoldCounts(key => single), Dict(key => (hold = single, throws = 4))
    old = Summary(Accesses((parameter(2), false, EffectKind.memory) => Effect(NO_DOUBT, 3, "")), Accesses(), Edges(), Holds(), Holds(), Dict{GlobalRef, Nodes}(), Set{Callback}(), Nodes(), 1, false, true, old_holds, old_holds, old_unguarded)
    new_unguarded = Dict(key => (hold = single, throws = 5))
    new = Summary(Accesses((parameter(2), false, EffectKind.memory) => Effect(CODE_DOUBT, 2, "")), Accesses(), Edges(), Holds(), Holds(), Dict{GlobalRef, Nodes}(), Set{Callback}(), Nodes(), 0, true, false, HoldCounts(key => HoldCount(2, Level.none, 2, "")), old_holds, new_unguarded)
    widened = widen(old, new)
    @test widened.writes == Accesses((parameter(2), false, EffectKind.memory) => Effect(BLIND_DOUBT, 3, UNSETTLED))
    # Hold count and unguarded hold that change become blind; equal ones stay.
    @test widened.held == HoldCounts(key => unsettled(single)) && widened.thrown == old_holds
    @test widened.unguarded == Dict(key => (hold = unsettled(single), throws = 4))
    @test widened.fresh == 1 && widened.closed_world && widened.cut
    # Callback records of both summaries stay.
    instance = only(something(dispatch(Any[typeof(CASES.set_value!), CASES.Box, Int], Base.get_world_counter(), 1)))
    record = Callback((variant = (instance, Pair{Int, Any}[]), parameters = [Nodes(Node.Placed(parameter(2)) => NO_DOUBT)]))
    recorded = Summary(Accesses(), Accesses(), Edges(), Holds(), Holds(), Dict{GlobalRef, Nodes}(), Set([record]), Nodes(), 0, false, false, HoldCounts(), HoldCounts(), Dict{Tuple{Node.Type, Resource.T}, Unguarded}())
    @test widen(recorded, new).callbacks == Set([record]) && widen(new, recorded).callbacks == Set([record])
    @check max_examples = 300 db = false function widen_grows(old = SUMMARIES, new = SUMMARIES)
        widened = widen(old, new)
        kept = all(issubset(keys(getfield(summary, name)), keys(getfield(widened, name))) for summary in (old, new), name in (:writes, :reads, :result))
        # Least doubt per node: level never rises; `code` sources only grow.
        certain = all(at_most(widened.result[node], doubt) for summary in (old, new) for (node, doubt) in summary.result)
        same(widen(widened, new), widened) && kept && certain && widened.fresh >= max(old.fresh, new.fresh) && widened.cut == (old.cut || new.cut)
    end
    # Rerun chain: access changes at most once after it appears, so finite places bound reruns.
    @check max_examples = 300 db = false function widened_chain_settles(chain = Data.Vectors(SUMMARIES; min_size = 1, max_size = 6))
        history = accumulate(widen, chain)
        all(union((keys(summary.writes) for summary in history)...)) do key
            present = [haskey(summary.writes, key) for summary in history]
            seen = [summary.writes[key] for summary in history if haskey(summary.writes, key)]
            issorted(present) && count(position -> seen[position] != seen[position + 1], 1:(length(seen) - 1)) <= 1
        end
    end
end

@testset "effects budget" begin
    # Flow past budget stops: variant gets open summary with budget cause, and root keeps no call facts.
    tight = start_run(nothing, Module[]; work_limit = 0)
    root = (only(something(dispatch(Any[typeof(fill_one!), Vector{Int}], tight.world, 1))), Pair{Int, Any}[])
    solve!(tight, [root])
    @test tight.slots[root].over_budget && same(root_summary!(tight, root), open_summary(2, Summaries.BUDGET)) && isempty(root_calls!(tight, root))
    # Default budget keeps same variant precise.
    roomy = start_run(nothing, Module[])
    solve!(roomy, [root])
    @test !any(slot -> slot.over_budget, values(roomy.slots)) && !same(root_summary!(roomy, root), open_summary(2, Summaries.BUDGET))
    # Variant past budget keeps open summary: rerun runs no flow, so roomy run returns open summary too.
    roomy.slots[root].over_budget = true
    @test same(first(Summaries.variant_summary!(roomy, root, false)), open_summary(2, Summaries.BUDGET)) && isempty(last(Summaries.variant_summary!(roomy, root, false)))
    roomy.slots[root].over_budget = false
    # Trace counts origins it walks, and load past budget stops: one call statement cannot run past limit.
    code = roomy.codes[root]
    spent = start_flow(code.ir, code.outcomes, code.message, false, false, Sources[], false, false, 1)
    holder = Targets(Origin.Allocation(30) => NO_DOUBT)
    store!(spent, holder, Step.Field(:z), Targets(Origin.Caller(parameter(2)) => NO_DOUBT))
    @test !isempty(load!(spent, holder, Step.Field(:z))) && over_budget(spent) && isempty(load!(spent, holder, Step.Field(:z)))
    # Package unit past budget: blind access with budget cause goes to coverage line.
    _, spots = cached_effects(PACKAGE, UNITS, Union{Nothing, UnitVerdict}[], nothing, Library(); work_limit = 0)
    @test any(spot -> spot.cause == Summaries.BUDGET, spots) && !any(spot -> spot.cause == Summaries.BUDGET, SPOTS)
end

const STEP_DRAWS = Data.OneOf(map(Step.Field, Data.SampledFrom([:x, :y])), map(Step.Position, Data.Integers(1, 2)), Data.Just(Step.Element()))
const ROOT_DRAWS = Data.OneOf(map(Root.Parameter, Data.Integers(1, 2)), map(name -> Root.Global(GlobalRef(Main, name)), Data.SampledFrom([:a, :b])), Data.Just(Root.Elsewhere()))
const PLACE_DRAWS = Data.OneOf(map(((root, steps),) -> Place.At(root, steps), Data.Pairs(ROOT_DRAWS, Data.Vectors(STEP_DRAWS; max_size = 2))), map(Place.Deep, ROOT_DRAWS))
const ORIGIN_DRAWS = Data.OneOf(map(Origin.Caller, PLACE_DRAWS), map(Origin.Allocation, Data.Integers(1, 2)), Data.Just(Origin.Unknown()))
const NODE_DRAWS = Data.OneOf(map(Node.Placed, PLACE_DRAWS), map(Node.Fresh, Data.Integers(1, 2)), Data.Just(Node.Outside()))

@testset "hash agrees with equality" begin
    # Each draw builds its own step vector and binding, so equal values share no object.
    for (name, draws) in (("steps", STEP_DRAWS), ("roots", ROOT_DRAWS), ("places", PLACE_DRAWS), ("origins", ORIGIN_DRAWS), ("nodes", NODE_DRAWS))
        @testset "$name" begin
            @check max_examples = 300 db = false function equal_iff_same_hash(drawn = Data.Pairs(draws, draws))
                one, other = drawn
                isequal(one, other) == (hash(one) == hash(other)) && hash(one, UInt(1)) != hash(one, UInt(2))
            end
        end
    end
end

"""Builds thrown value: open `print` on `x` writes nothing caller sees (`engine.md`, Effect kinds)."""
message_write(x::Any, flag::Bool) = flag ? throw(ArgumentError(string("bad ", x))) : nothing

"""Same `string` call, result goes to log: open `print` keeps `possible` write."""
logged_write!(log::Vector{String}, x::Any) = (push!(log, string(x)); nothing)

"""Message holds `pop!`: its definite write on stack stays."""
pop_message!(stack::Vector{Any}, flag::Bool) = flag ? throw(ArgumentError(string("top ", pop!(stack)))) : nothing

"""Open call before throw: caller that catches sees its write."""
open_then_throw!(f::Any, x::Any, flag::Bool) = flag ? (f(x); error("failed")) : nothing

"""Throw helper `error` builds message itself: its summary adds no write."""
error_message(x::Any, flag::Bool) = flag ? error("bad ", x) : nothing

"""Message built in loop: use cycle keeps `string` call out of message, so its write stays."""
function loop_message(parts::Vector{Any}, flag::Bool)::Nothing
    text = ""
    for part in parts
        text = string(text, part)
    end
    flag && throw(ArgumentError(text))
    return nothing
end

"""
Previous part thrown: loop phi feeds message only, and `string` call feeds phi only. Phi comes first in IR, so `string`
call joins message on second pass.
"""
function previous_part_message(parts::Vector{Any}, flag::Bool)::Nothing
    text = ""
    for part in parts
        flag && throw(ArgumentError(text))
        text = string(part)
    end
    return nothing
end

"""Package text of `x`: open `print` gives `possible` write."""
described(x::Any)::String = string(x)

"""Message from static call: callee summary applies inside message."""
describe_message(x::Any, flag::Bool) = flag ? throw(ArgumentError(described(x))) : nothing

"""Package text of `y`, by type of `x`: call on `Any` joins both methods."""
shown(::Int, y::Any)::String = string(y)
shown(::Float64, y::Any)::String = string(y)

"""Message from joined call: join goes inside message."""
join_message(x::Any, y::Any, flag::Bool) = flag ? throw(ArgumentError(shown(x, y))) : nothing

"""Message from contract call with breach: `iterate` on `Any` may consume `Iterators.Stateful`."""
breach_message(x::Any, flag::Bool) = flag ? throw(ArgumentError(string(iterate(x)))) : nothing

"""Definite write before message, then same write inside message: write keeps first cause."""
pop_twice!(stack::Vector{Any}, flag::Bool) = (pop!(stack); flag ? throw(ArgumentError(string(pop!(stack)))) : nothing)

"""Run and root of `f` on argument `types`, solved with `modules` as package code."""
function solved(f::Any, modules::Vector{Module}, types::Type...)::Tuple{Summaries.Run, Variant}
    run = start_run(nothing, modules)
    root = (only(something(dispatch(Any[typeof(f), types...], run.world, 1))), Pair{Int, Any}[])
    solve!(run, [root])
    return run, root
end

"""Open call builds thrown value: its writes go nowhere caller sees."""
open_message(f::Any, x::Any, flag::Bool) = flag ? throw(ArgumentError(f(x))) : nothing

"""Text unchanged; no method takes second argument."""
takes_text(text::String)::String = text

"""Call that fails on its argument types is no throw helper: `string` call result feeds no thrown value."""
fails_on_arity(parts::Vector{Any}) = takes_text(string(parts[1]), 1)

"""Callable that holds box of caller: writes value, returns old value."""
struct Taker
    box::CASES.Box
end

(taker::Taker)(value::Int)::Int = (old = taker.box.value; taker.box.value = value; old)

"""Message call with callable from caller: record resolves at call, so caller sees definite write alone."""
report_taker!(taker::Taker, value::Int, flag::Bool)::Nothing = flag ? throw(ArgumentError(string(taker(value)))) : nothing

@testset "throw paths" begin
    element = Step.Element()
    # Message call adds no `possible` write; same call feeding log keeps it.
    @test isempty(summary_of(message_write, Any, Bool).writes) && isempty(summary_of(open_message, Any, Any, Bool).writes)
    @test isempty(summary_of(previous_part_message, Vector{Any}, Bool).writes)
    @test doubts(summary_of(logged_write!, Vector{String}, Any).writes) == Dict(top(2) => NO_DOUBT, (parameter(3), true) => sourced(3))
    # Static call, join and contract breach inside message add no `possible` write.
    @test isempty(summary_of(describe_message, Any, Bool).writes) && isempty(summary_of(breach_message, Any, Bool).writes)
    @test isempty(root_summary!(solved(join_message, Module[@__MODULE__], Any, Any, Bool)...).writes)
    # Definite write inside message stays, and so does write before throw; earlier write keeps its cause.
    @test doubts(summary_of(pop_message!, Vector{Any}, Bool).writes) == Dict(top(2) => NO_DOUBT)
    run, root = solved(pop_twice!, Module[], Vector{Any}, Bool)
    @test !run.codes[root].message[root_summary!(run, root).writes[memory(top(2))].cause]
    @test level_of(summary_of(open_then_throw!, Any, Any, Bool).writes[memory((parameter(3), true))].doubt) == Level.code
    @test isempty(summary_of(error_message, Any, Bool).writes)
    # Use cycle never counts as message; call that fails on its types is no throw.
    @test doubts(summary_of(loop_message, Vector{Any}, Bool).writes) == Dict((parameter(2, element), true) => sourced(2))
    @test doubts(summary_of(fails_on_arity, Vector{Any}).writes) == Dict((parameter(2, element), true) => sourced(2))
    # Callback record of message call resolves there: definite write, no record left for caller.
    raw = raw_summary(report_taker!, Taker, Int, Bool)
    @test isempty(raw.callbacks) && doubts(raw.writes) == Dict((parameter(2, Step.Field(:box)), false) => NO_DOUBT)
end

"""Line to IO argument: open `println` writes IO."""
log_line(io::IO, x::Int) = println(io, x)

"""Byte into buffer: definite IO write."""
write_byte!(io::IOBuffer, b::UInt8) = write(io, b)

"""Line to `stdout`: global binding declared `IO`."""
say(x::Int) = println(stdout, x)

"""Shows `source` on `destination`: open `show` writes `destination` for sure, and `source` only as open operand."""
show_stream(destination::IO, source::IO) = show(destination, source)

"""Copies `source` into `destination`: open `write` reads `source`, so it writes both for sure."""
copy_stream(destination::IO, source::IO) = write(destination, source)

"""Holder of buffer: path crosses `IO` at field."""
struct Logger
    io::IOBuffer
end

log_byte!(logger::Logger, b::UInt8) = write(logger.io, b)

"""Plain vector write; caller whose path crosses `IO` makes it IO write."""
push_byte!(bytes::Vector{UInt8}, b::UInt8) = (push!(bytes, b); nothing)

"""IO that keeps bytes in plain vector."""
struct Sink <: IO
    bytes::Vector{UInt8}
end

sink_push!(sink::Sink, b::UInt8) = push_byte!(sink.bytes, b)

roll(rng::Xoshiro) = rand(rng)
roll_open(rng::AbstractRNG) = rand(rng)
shuffle_open!(rng::AbstractRNG, items::Vector{Int}) = Random.shuffle!(rng, items)
roll_default() = rand()
"""Reseed of default RNG: `seed!` also copies new state into seed record in task storage."""
reseed!()::Nothing = (Random.seed!(); nothing)
"""Reseed with package integer seed: hash of seed runs package code, so audit does not cover it."""
reseed_with!(seed::Integer)::Nothing = (Random.seed!(seed); nothing)
remember!(x::Int) = task_local_storage(:effects_test, x)

"""Sets `v` as result of current task, then pushes into result of task from task storage: maybe `v`."""
function other_result!(v::Vector{Int})::Nothing
    current_task().result = v
    push!((task_local_storage(:effects_task)::Task).result::Vector{Int}, 1)
    return nothing
end

"""Stores `v` in task storage, loads it back by same key and pushes: writes `v`."""
function stash_push!(v::Vector{Int})::Nothing
    task_local_storage(:effects_stash, v)
    push!(task_local_storage(:effects_stash)::Vector{Int}, 1)
    return nothing
end

"""Pushes into vector in task storage."""
push_stash!()::Nothing = (push!(task_local_storage(:effects_stash)::Vector{Int}, 1); nothing)

"""Stores `v` in task storage, then pushes through callee: writes `v`."""
function stash_call!(v::Vector{Int})::Nothing
    task_local_storage(:effects_stash, v)
    push_stash!()
    return nothing
end

"""Pushes into `v`, then into vector in task storage: `v` stays inside caller places."""
own_then_stash!(v::Vector{Int})::Nothing = (push!(v, 1); push_stash!(); nothing)
"""Stores `v` in task storage, then sets other task-local entry: changes task storage, never `v`."""
stash_remember!(v::Vector{Int})::Nothing = (task_local_storage(:effects_stash, v); remember!(1); nothing)
"""Sums vector in task storage: starts its iteration."""
function sum_stash()::Int
    total = 0
    for item in task_local_storage(:effects_stash)::Vector{Int}
        total += item
    end
    return total
end
"""Stores `items` in task storage, then sums them through callee: may start iteration of `items`."""
stash_sum!(items::Vector{Int})::Int = (task_local_storage(:effects_stash, items); sum_stash())
"""Assigns `v` into `Ref` in task storage."""
assign_stash!(v::Vector{Int})::Nothing = ((task_local_storage(:effects_stash)::Base.RefValue{Vector{Int}})[] = v; nothing)
"""Stores `holder` in task storage, assigns `v` into it through callee, then returns `holder[]`: may return `v`."""
function stash_assign!(holder::Base.RefValue{Vector{Int}}, v::Vector{Int})::Vector{Int}
    task_local_storage(:effects_stash, holder)
    assign_stash!(v)
    return holder[]
end

"""Whether `summary` writes memory on or below parameter `position` in `code` doubt."""
writes_in_doubt(summary::Summary, position::Int)::Bool = any(kind == EffectKind.memory && root_of(place) == Root.Parameter(position) && level_of(effect.doubt) == Level.code for ((place, _, kind), effect) in summary.writes)

"""Scoped value: read of current task scope."""
const LEVEL = ScopedValue(1)
level() = LEVEL[]

"""Package scoped value whose default writes object in code: `ScopedValues.get` runs package code."""
struct Counted <: Base.ScopedValues.AbstractScopedValue{Int} end
Base.ScopedValues.hasdefault(::Counted) = true
@eval Base.ScopedValues.getdefault(::Counted) = (push!($(Int[]), 1); 1)
counted_level() = Counted()[]

hold!(l::ReentrantLock) = lock(l)
matches(r::Regex, s::String) = occursin(r, s)
text_of(s::LazyString) = String(s)
note(x::Int) = @info "note" x
warn_old(x::Int) = (Base.depwarn("old", :warn_old); x)
temp_folder() = mktempdir()
keep_handle(t::Timer) = Base.preserve_handle(t)
toml_of(path::String) = Base.parsed_toml(path)
take_value(channel::Channel{Int}) = take!(channel)
"""Stores `v` in task storage, then waits on `channel`: scheduler writes to fields of current task reach no stored object."""
stash_taken!(v::Vector{Int}, channel::Channel{Int})::Nothing = (task_local_storage(:effects_stash, v); take!(channel); nothing)
"""Notifies condition from task storage: object caller may have stored there."""
@noinline notify_stashed()::Nothing = (notify(task_local_storage(:effects_cond)::Threads.Condition); nothing)
"""Lets task `t` run on any thread: package write to scheduler field of task caller gave."""
unpin(t::Task) = (t.sticky = false; nothing)
"""Starts task `t`: scheduler changes fields of task caller gave."""
start_task(t::Task) = (schedule(t); nothing)
"""Stores `c` in task storage, then notifies condition from there: maybe `c`."""
stash_notify!(c::Threads.Condition)::Nothing = (task_local_storage(:effects_cond, c); notify_stashed(); nothing)
project_of(env::String) = Base.env_project_file(env)
doc_meta(m::Module) = Base.Docs.meta(m)
frame_color(m::Module) = Base.get_stacktrace_color(m)
version_of(m::Module) = pkgversion(m)
set_origin(id::Base.PkgId, path::String) = Base.set_pkgorigin_version_path(id, path)
include_into(m::Module, path::String) = Base.include(m, path)
scratch_folder(key::String) = Scratch.get_scratch!(Corset, key)
write_text(s::Serialization.Serializer{IOBuffer}, text::String) = Serialization.serialize(s, text)
"""Serialized bytes of `type`: stream numbering of type names writes Serialization globals."""
type_bytes(type::DataType)::Vector{UInt8} = (stream = IOBuffer(); Serialization.serialize(stream, type); take!(stream))
"""Package serializer with own field beside stream state."""
mutable struct Tagged <: Serialization.AbstractSerializer
    io::IOBuffer
    counter::Int
    table::IdDict{Any, Any}
    pending_refs::Vector{Int}
    tags::Vector{Int}
end
tag!(s::Tagged) = (push!(s.tags, 1); s.counter += 1)
rename_project(path::String) = (Base.parsed_toml(path)["name"] = "renamed"; nothing)
grow_load_path(path::String) = (push!(Base.load_path(), path); nothing)

"""Kinds of accesses in `table` on places with `root`."""
kinds_at(table::Dict{Tuple{Place.Type, Bool, EffectKind.T}, Effect}, root::Root.Type)::Set{EffectKind.T} = Set(kind for (place, _, kind) in keys(table) if root_of(place) == root)

@testset "effect kinds" begin
    io, elsewhere = EffectKind.io, Root.Elsewhere()
    # IO by declared type of argument, global, or field on path. Open `write` inside `println` writes its `IO` for sure.
    @test doubts(summary_of(log_line, IO, Int).writes) == Dict((parameter(2), true, io) => NO_DOUBT)
    # Stream operand alone takes definite write: shown value keeps open-call doubt.
    shown = doubts(summary_of(show_stream, IO, IO).writes)
    @test shown[(parameter(2), true, io)] == NO_DOUBT && get(shown, (parameter(3), true, io), nothing) != NO_DOUBT
    @test doubts(summary_of(copy_stream, IO, IO).writes) == Dict((parameter(2), true, io) => NO_DOUBT, (parameter(3), true, io) => NO_DOUBT)
    @test isempty(Corset.Effects.stream_positions(display, 2)) && isempty(Corset.Effects.stream_positions(show, 1))
    @test Corset.Effects.stream_positions(show, 2) == 1:1 && Corset.Effects.stream_positions(print, 0) == 1:0
    @test doubts(summary_of(write_byte!, IOBuffer, UInt8).writes) == Dict((parameter(2), false, io) => NO_DOUBT)
    @test Set(kind for (_, _, kind) in keys(summary_of(say, Int).writes)) == Set([io])
    @test doubts(summary_of(log_byte!, Logger, UInt8).writes) == Dict((parameter(2, Step.Field(:io)), false, io) => NO_DOUBT)
    # Caller classifies callee memory write again by own path.
    @test doubts(summary_of(push_byte!, Vector{UInt8}, UInt8).writes) == Dict(top(2) => NO_DOUBT)
    @test doubts(summary_of(sink_push!, Sink, UInt8).writes) == Dict((parameter(2, Step.Field(:bytes)), false, io) => NO_DOUBT)
    # RNG argument, default RNG in `Task` fields, task-local storage, scoped read.
    @test doubts(summary_of(roll, Xoshiro).writes) == Dict((parameter(2), false, EffectKind.rng_argument) => NO_DOUBT)
    # Open call of Random draw function draws from RNG argument, whatever method runs; other effects stay open.
    @test doubts(summary_of(roll_open, AbstractRNG).writes)[(parameter(2), false, EffectKind.rng_argument)] == NO_DOUBT
    @test doubts(summary_of(shuffle_open!, AbstractRNG, Vector{Int}).writes)[(parameter(2), false, EffectKind.rng_argument)] == NO_DOUBT
    @test (parameter(2), false, EffectKind.rng_argument) in keys(summary_of(roll_open, AbstractRNG).reads)
    # Current task is unknown object without doubt: draw writes default RNG for sure, and nothing else for sure.
    rolled = summary_of(roll_default)
    rolled_writes = doubts(rolled.writes)
    # Variants of `getproperty(::Task, ::Symbol)` for RNG fields drop its other branches: draw writes nothing else.
    @test rolled_writes == Dict((Place.At(elsewhere, Step.Type[]), false, EffectKind.default_rng) => NO_DOUBT)
    @test EffectKind.default_rng in kinds_at(rolled.reads, elsewhere)
    # Seed record copy and task storage lookup are default RNG state: reseed writes default RNG, nothing else.
    @test doubts(summary_of(reseed!).writes) == Dict((Place.At(elsewhere, Step.Type[]), false, EffectKind.default_rng) => NO_DOUBT)
    @test doubts(summary_of(reseed_with!, Int).writes) == doubts(summary_of(reseed!).writes)
    # Audit needs bits integer seed: other seed keeps memory kinds.
    @test EffectKind.memory in kinds_at(summary_of(reseed_with!, Integer).writes, elsewhere)
    # Unknown object merges every outside object: vector stored into it stays in doubt when other task loads it.
    @test level_of(doubts(summary_of(other_result!, Vector{Int}).writes)[top(2)]) == Level.code
    # Callee object outside caller places may be any object caller stored outside: result and callee write alike.
    @test writes_in_doubt(summary_of(stash_push!, Vector{Int}), 2)
    @test writes_in_doubt(summary_of(stash_call!, Vector{Int}), 2)
    owned = summary_of(own_then_stash!, Vector{Int})
    @test doubts(owned.writes)[top(2)] == NO_DOUBT && !writes_in_doubt(owned, 2)
    # Callee store into caller object outside lands in its own slots: later load through `holder` finds `v`.
    @test haskey(summary_of(stash_assign!, Base.RefValue{Vector{Int}}, Vector{Int}).result, Node.Placed(parameter(3)))
    # Outside state access stays on unknown object: task-local write never lands on object caller stored outside.
    stashed = summary_of(stash_remember!, Vector{Int})
    @test any(kind == EffectKind.task_local && root_of(place) == Root.Elsewhere() for (place, _, kind) in keys(stashed.writes))
    @test !any(kind == EffectKind.task_local && root_of(place) == Root.Parameter(2) for (place, _, kind) in keys(stashed.writes))
    # Access to object, such as iteration start, reaches object caller stored outside.
    @test any(kind == EffectKind.iteration && root_of(place) == Root.Parameter(2) for (place, _, kind) in keys(summary_of(stash_sum!, Vector{Int}).reads))
    remembered = summary_of(remember!, Int)
    @test kinds_at(remembered.writes, elsewhere) == Set([EffectKind.task_local])
    # Audited method covers its root only: global read inside it keeps own kind.
    @test all(kind != EffectKind.task_local for (place, _, kind) in keys(remembered.reads) if root_of(place) != elsewhere)
    @test (Place.At(elsewhere, Step.Type[]), false, EffectKind.scoped_read) in keys(summary_of(level).reads)
    # Lookup in scope dictionary is scoped read too: no memory read on `Elsewhere`.
    @test kinds_at(summary_of(level).reads, elsewhere) == Set([EffectKind.scoped_read])
    # Lookup passes constant `false` to copy-on-write flag of `HAMT.path`, so read writes nothing.
    @test isempty(summary_of(level).writes)
    # Audit holds for `ScopedValue` only: write of package default keeps memory kind.
    @test kinds_at(summary_of(counted_level).writes, elsewhere) == Set([EffectKind.memory])
    # Audited table: lazy compile, lazy text, PCRE contexts, logging state, `BigFloat` pointer repair.
    matched = summary_of(matches, Regex, String).writes
    @test matched[(parameter(2), false, EffectKind.lazy_init)].doubt == NO_DOUBT
    # PCRE table: JIT compile writes below audited `Regex` field; every write of match is definite.
    @test matched[(parameter(2, Step.Field(:regex)), false, EffectKind.lazy_init)].doubt == NO_DOUBT
    # Rebinding `THREAD_MATCH_CONTEXTS` keeps old vector beside new one (no strong update): its sure write reads as `possible`.
    contexts = Root.Global(GlobalRef(Base.PCRE, :THREAD_MATCH_CONTEXTS))
    @test all(effect -> effect.doubt == NO_DOUBT, (effect for ((place, _, _), effect) in matched if root_of(place) != contexts))
    @test_broken all(effect -> effect.doubt == NO_DOUBT, (effect for ((place, _, _), effect) in matched if root_of(place) == contexts))
    @test EffectKind.audited in kinds_at(matched, Root.Global(GlobalRef(Base.PCRE, :THREAD_MATCH_CONTEXTS)))
    @test summary_of(text_of, LazyString).writes[(parameter(2), false, EffectKind.lazy_init)].doubt == NO_DOUBT
    @test EffectKind.audited in kinds_at(summary_of(note, Int).reads, Root.Global(GlobalRef(Base.CoreLogging, :_global_logstate)))
    @test kinds_at(summary_of(Base.unsafe_convert, Type{Ref{BigFloat}}, Base.MPFR.BigFloatData).writes, Root.Parameter(3)) == Set([EffectKind.audited])
    # `JULIA_DEBUG` cache and frame lookup of deprecation write unknown objects as audited state only.
    for logs in (note, warn_old)
        @test !any(kind == EffectKind.memory && root_of(place) == elsewhere && level_of(effect.doubt) == Level.code for ((place, _, kind), effect) in summary_of(logs, Int).writes)
    end
    # IO bookkeeping and lazy Base caches take audited kind: no definite state write remains for `bang-convention`.
    for (f, types, globals, kind) in (
            (temp_folder, (), [GlobalRef(Base.Filesystem, :TEMP_CLEANUP), GlobalRef(Base.Filesystem, :TEMP_CLEANUP_MAX)], io),
            (keep_handle, (Timer,), [GlobalRef(Base, :uvhandles)], io),
            (toml_of, (String,), [GlobalRef(Base, :TOML_CACHE), GlobalRef(Base, :LOADING_CACHE)], EffectKind.lazy_init),
            (project_of, (String,), [GlobalRef(Base, :LOADING_CACHE)], EffectKind.lazy_init),
            (doc_meta, (Module,), [GlobalRef(Base.Docs, :modules)], EffectKind.lazy_init),
            (frame_color, (Module,), [GlobalRef(Base, :STACKTRACE_FIXEDCOLORS), GlobalRef(Base, :STACKTRACE_MODULECOLORS)], EffectKind.lazy_init),
            (version_of, (Module,), [GlobalRef(Base, :pkgorigins)], EffectKind.lazy_init),
            (scratch_folder, (String,), [GlobalRef(Scratch, :scratch_access_timers)], io),
            (type_bytes, (DataType,), [GlobalRef(Serialization, :object_numbers), GlobalRef(Serialization, :obj_number_salt)], io),
        )
        writes = summary_of(f, types...).writes
        @test all(ref -> kind in kinds_at(writes, Root.Global(ref)) && !(EffectKind.memory in kinds_at(writes, Root.Global(ref))), globals)
        @test !any(written in (EffectKind.memory, EffectKind.task_local) && effect.doubt == NO_DOUBT for ((_, _, written), effect) in writes)
    end
    # Channel wait changes Base task queues: synchronization, never memory.
    scheduled = summary_of(take_value, Channel{Int}).writes
    for ref in (GlobalRef(Base, :Workqueues), GlobalRef(Base.Partr, :heaps))
        @test EffectKind.synchronization in kinds_at(scheduled, Root.Global(ref)) && !(EffectKind.memory in kinds_at(scheduled, Root.Global(ref)))
    end
    # Wait changes scheduler fields of current task (`sticky`, `result`): audited state, never task-local state.
    @test EffectKind.audited in kinds_at(scheduled, Root.Elsewhere()) && !any(kind == EffectKind.task_local for (_, _, kind) in keys(scheduled))
    # Scheduler field of current task reaches no object caller stored; condition from task storage reaches caller one.
    pinned = summary_of(stash_taken!, Vector{Int}, Channel{Int}).writes
    @test EffectKind.audited in kinds_at(pinned, Root.Elsewhere()) && !(EffectKind.audited in kinds_at(pinned, Root.Parameter(2)))
    @test EffectKind.synchronization in kinds_at(summary_of(stash_notify!, Threads.Condition).writes, Root.Parameter(2))
    # Package write to scheduler field of task it gets changes that task: task-local state, as `bang-convention` needs.
    @test kinds_at(summary_of(unpin, Task).writes, Root.Parameter(2)) == Set([EffectKind.task_local])
    # Base `schedule` changes scheduler fields of task it gets: audited state, as for current task.
    started = kinds_at(summary_of(start_task, Task).writes, Root.Parameter(2))
    @test EffectKind.audited in started && !(EffectKind.task_local in started)
    # `include` evaluates code, so blind writes of every kind stay; its include record push is IO for sure.
    included, record = summary_of(include_into, Module, String).writes, Root.Global(GlobalRef(Base, :_require_dependencies))
    @test included[(Place.At(record, Step.Type[]), false, io)].doubt == NO_DOUBT
    @test !any(kind == EffectKind.memory && effect.doubt == NO_DOUBT for ((place, _, kind), effect) in included if root_of(place) == record)
    # Version cache of `pkgversion` is lazy; path change of package origin record stays memory.
    @test EffectKind.memory in kinds_at(summary_of(set_origin, Base.PkgId, String).writes, Root.Global(GlobalRef(Base, :pkgorigins)))
    # Audited global kind holds in Base methods only: package write through cached `Dict` or `Vector` is memory.
    @test EffectKind.memory in kinds_at(summary_of(rename_project, String).writes, Root.Global(GlobalRef(Base, :TOML_CACHE)))
    load_path = Place.At(Root.Global(GlobalRef(Base, :LOADING_CACHE)), Step.Type[Step.Field(:x), Step.Field(:load_path)])
    @test haskey(summary_of(grow_load_path, String).writes, (load_path, false, EffectKind.memory))
    # Helpers: special types, `Task` fields, field index, step types.
    @test special_kind(IOBuffer) == io && isnothing(special_kind(Union{})) && isnothing(special_kind(1)) && special_kind(Base.Semaphore) == EffectKind.synchronization
    # Serializer stream state (back-reference table, counter) is IO; package field of serializer stays memory.
    serialized_writes = summary_of(write_text, Serialization.Serializer{IOBuffer}, String).writes
    @test io in kinds_at(serialized_writes, Root.Parameter(2)) && !(EffectKind.memory in kinds_at(serialized_writes, Root.Parameter(2)))
    tagged = summary_of(tag!, Tagged).writes
    @test kinds_at(tagged, Root.Parameter(2)) == Set([EffectKind.memory, io])
    @test audited_field(Serialization.Serializer{IOBuffer}, :known_object_data) == io && isnothing(audited_field(Tagged, :known_object_data))
    @test isnothing(audited_field(Tagged, :tags)) && isnothing(audited_field(Any, :table)) && audited_field(Regex, :regex) == EffectKind.lazy_init
    @test (site_kind(Task, :rngState0, false), site_kind(Task, :scope, false), site_kind(Task, :storage, true)) == (EffectKind.default_rng, EffectKind.scoped_read, EffectKind.task_local)
    @test (site_kind(Task, :sticky, true), site_kind(Task, :result, true), site_kind(Task, :sticky, false), site_kind(Task, nothing, true)) == (EffectKind.audited, EffectKind.audited, EffectKind.task_local, EffectKind.task_local)
    # Property accessor runs field access of its caller; other Base methods own scheduler state.
    @test scheduler_method(which(schedule, (Task,))) && !scheduler_method(which(setproperty!, (Task, Symbol, Any))) && !scheduler_method(only(methods(unpin)))
    @test field_kind(Regex, Some{Any}(4), false) == EffectKind.lazy_init && field_kind(Tuple{IOBuffer}, Some{Any}(1), false) == EffectKind.memory && field_kind(IOBuffer, nothing, false) == io
    @test step_type(Tuple{Vararg{Int}}, Step.Position(3)) == Int && step_type(Tuple{Int}, Step.Position(2)) == Union{} && step_type(Vector{IOBuffer}, Step.Element()) == IOBuffer
    @test step_type(Any, Step.Field(:x)) == Any && step_type(Logger, Step.Field(:missing)) == Union{} && step_type(Dict{Int, Int}, Step.Element()) == Any
    @test step_type(AbstractVector{Int}, Step.Field(:missing)) == Any && step_type(Tuple{Vararg{Int}}, Step.Field(:missing)) == Any
    # Summary of struct family reads field by position: concrete caller type resolves it.
    @test step_type(Logger, Step.Position(1)) == fieldtype(Logger, 1) && step_type(Logger, Step.Position(9)) == Union{} && step_type(AbstractVector{Int}, Step.Position(1)) == Any
end

"""Holder of lock: hold lands on field place."""
struct Guarded
    lk::ReentrantLock
end

"""Holder of lock whose `grab` holds nothing: join of `grab` methods disagrees."""
struct Lockless
    lk::ReentrantLock
end

store_bare!(l::ReentrantLock, x::Vector{Int}) = (lock(l); x[1] = 1; unlock(l); nothing)
function store_finally!(l::ReentrantLock, x::Vector{Int})
    lock(l)
    try
        x[1] = 1
    finally
        unlock(l)
    end
    return nothing
end
store_macro!(l::ReentrantLock, x::Vector{Int}) = (@lock l (x[1] = 1); nothing)
store_do!(l::ReentrantLock, x::Vector{Int}) = (lock(() -> (x[1] = 1), l); nothing)
acquire_guard!(q::Guarded) = lock(q.lk)
release_guard!(q::Guarded) = unlock(q.lk)
guard_pair!(q::Guarded, x::Vector{Int}) = (acquire_guard!(q); x[1] = 1; release_guard!(q); nothing)
function catch_pair!(q::Guarded, x::Vector{Int})
    try
        guard_pair!(q, x)
    catch
    end
    return nothing
end
maybe_lock!(l::ReentrantLock, flag::Bool) = (flag && lock(l); nothing)
paired_lock!(l::ReentrantLock, flag::Bool, x::Vector{Int}) = (flag && lock(l); x[1] = 1; flag && unlock(l); nothing)
function lock_each!(l::ReentrantLock, n::Int)
    for _ in 1:n
        lock(l)
    end
    return nothing
end
write_file(path::String) = (f = open(path, "w"); write(f, 0x01); close(f); nothing)
write_file_do(path::String) = (open(f -> write(f, 0x01), path, "w"); nothing)
stream_byte(io::IOStream) = (write(io, 0x01); nothing)
slot_store!(s::Base.Semaphore, x::Vector{Int}) = (Base.acquire(s); x[1] = 1; Base.release(s); nothing)
try_unlock(l::ReentrantLock) = trylock(l) && (unlock(l); true)
function wait_signal(c::Threads.Condition)
    lock(c)
    try
        wait(c; first = true)
    finally
        unlock(c)
    end
    return nothing
end
const GLOBAL_LOCK = ReentrantLock()
hold_global() = lock(GLOBAL_LOCK)
function store_caught!(l::ReentrantLock, x::Vector{Int})
    lock(l)
    try
        x[1] = 1
    catch
    end
    unlock(l)
    return nothing
end
function store_rethrow!(l::ReentrantLock, x::Vector{Int})
    lock(l)
    try
        x[1] = 1
    catch
        rethrow()
    end
    unlock(l)
    return nothing
end
function scoped_store!(l::ReentrantLock, x::Vector{Int})
    lock(l)
    try
        Base.ScopedValues.@with LEVEL => 2 (x[1] = 1)
    finally
        unlock(l)
    end
    return nothing
end
run_closure(f) = (f(); nothing)
lock_through!(q::Guarded) = (run_closure(() -> lock(q.lk)); nothing)
grab!(q::Guarded) = lock(q.lk)
grab!(::Lockless) = nothing
grab_either!(q::Union{Guarded, Lockless}) = grab!(q)
pair_caller!(q::Guarded, x::Vector{Int}) = (guard_pair!(q, x); nothing)
lock_local() = (lock(ReentrantLock()); nothing)
closed_file(path::String) = (f = open(path, "w"); close(f); f)
"""Closure locks and throws: callback record carries hold to catch block of caller."""
function closure_throw!(q::Guarded)
    try
        run_closure(() -> (lock(q.lk); throw(ArgumentError("held"))))
    catch
    end
    return nothing
end
"""Field read on open type: lock operand reaches parameter with `code` doubt."""
lock_open!(q) = (lock(q.lk::ReentrantLock); nothing)
"""Global without value: read throws while method holds lock."""
global UNSET_COUNT::Int
read_locked(l::ReentrantLock) = (lock(l); count = UNSET_COUNT; unlock(l); count)
"""Join of `grab!` methods gives unknown hold; store throws while method may hold lock."""
grab_either_store!(q::Union{Guarded, Lockless}, x::Vector{Int}) = (grab!(q); x[1] = 1; nothing)
"""Release inside `try`: catch block gets states of statements that throw only, not state at `try` entry."""
function release_try!(l::ReentrantLock, x::Vector{Int})
    lock(l)
    try
        unlock(l)
        x[1] = 1
    catch
    end
    return nothing
end
"""Body of scope cannot throw, so its `enter` has no catch block (`catch_dest` 0) inside outer `try`."""
function scoped_sum(x::Int)
    return try
        Base.ScopedValues.@with LEVEL => 2 (x + 1)
    catch
        0
    end
end
lock_either!(flag::Bool, a::ReentrantLock, b::ReentrantLock) = (lock(flag ? a : b); nothing)

"""Hold of `summary` by caller node and resource: count and level."""
holds(table::HoldCounts)::Dict{Tuple{Node.Type, Resource.T}, Tuple{Int, Level.T}} = Dict(key => (hold.count, hold.level) for (key, hold) in table)

"""Node at parameter `position` and `steps`."""
placed(position::Int, steps::Step.Type...)::Node.Type = Node.Placed(parameter(position, steps...))

@testset "release balance" begin
    lock_, file, none, code, blind = Resource.lock, Resource.file, Level.none, Level.code, Level.blind
    lk = Step.Field(:lk)
    # Release skipped on throw: F98 fact at statement that throws; `finally`, `@lock`, do-block and `catch` give none.
    bare = summary_of(store_bare!, ReentrantLock, Vector{Int})
    @test isempty(bare.held) && holds(bare.thrown) == Dict((placed(2), lock_) => (0, code))
    @test only(values(bare.unguarded)).hold.count == 1 && only(keys(bare.unguarded)) == (placed(2), lock_)
    for (f, types) in ((store_finally!, (ReentrantLock, Vector{Int})), (store_macro!, (ReentrantLock, Vector{Int})), (store_do!, (ReentrantLock, Vector{Int})), (store_caught!, (ReentrantLock, Vector{Int})), (scoped_store!, (ReentrantLock, Vector{Int})), (write_file_do, (String,)), (wait_signal, (Threads.Condition,)))
        found = summary_of(f, types...)
        @test isempty(found.held) && isempty(found.thrown) && isempty(found.unguarded)
    end
    @test only(values(summary_of(store_rethrow!, ReentrantLock, Vector{Int}).unguarded)).hold.level == none
    @test only(values(summary_of(read_locked, ReentrantLock).unguarded)).hold.count == 1
    @test isempty(summary_of(release_try!, ReentrantLock, Vector{Int}).held)
    # Engine never reads lock or `wait` body: no scheduler writes.
    @test isempty(summary_of(wait_signal, Threads.Condition).writes)
    # Hold through callee: own acquire, callee normal exit, callback record; release balances it.
    @test holds(summary_of(acquire_guard!, Guarded).held) == Dict((placed(2, lk), lock_) => (1, none))
    @test holds(summary_of(release_guard!, Guarded).held) == Dict((placed(2, lk), lock_) => (-1, none))
    # Acquire that throws takes nothing; release that throws still counts.
    @test isempty(summary_of(acquire_guard!, Guarded).thrown)
    @test holds(summary_of(release_guard!, Guarded).thrown) == Dict((placed(2, lk), lock_) => (-1, none))
    pair = summary_of(guard_pair!, Guarded, Vector{Int})
    @test isempty(pair.held) && only(values(pair.unguarded)).hold.count == 1
    @test holds(summary_of(lock_through!, Guarded).held) == Dict((placed(2, lk), lock_) => (1, none))
    @test holds(summary_of(closure_throw!, Guarded).held) == Dict((placed(2, lk), lock_) => (0, code))
    @test holds(summary_of(hold_global).held) == Dict((Node.Placed(global_place(@__MODULE__, :GLOBAL_LOCK)), lock_) => (1, none))
    # Callee throw-exit count alone is no F98 fact; catch turns it into `possible` hold.
    caught = summary_of(catch_pair!, Guarded, Vector{Int})
    @test holds(caught.held) == Dict((placed(2, lk), lock_) => (0, code)) && isempty(caught.unguarded)
    passed = summary_of(pair_caller!, Guarded, Vector{Int})
    @test isempty(passed.unguarded) && holds(passed.thrown) == Dict((placed(2, lk), lock_) => (0, code))
    # Join of branches, loops and methods gives unknown; branch on same condition balances.
    @test holds(summary_of(maybe_lock!, ReentrantLock, Bool).held) == Dict((placed(2), lock_) => (0, code))
    @test isempty(summary_of(paired_lock!, ReentrantLock, Bool, Vector{Int}).held)
    @test holds(summary_of(lock_each!, ReentrantLock, Int).held) == Dict((placed(2), lock_) => (0, code))
    @test holds(root_summary!(solved(grab_either!, Module[@__MODULE__], Union{Guarded, Lockless})...).held) == Dict((placed(2, lk), lock_) => (0, code))
    either_store = root_summary!(solved(grab_either_store!, Module[@__MODULE__], Union{Guarded, Lockless}, Vector{Int})...)
    @test only(values(either_store.unguarded)).hold.level == code
    # `IOStream` code locks stream only when `_dolock` holds: same condition, so stream ends balanced.
    @test isempty(summary_of(stream_byte, IOStream).held)
    # Fresh file: hold stays local, its skipped `close` is F98 fact.
    opened = summary_of(write_file, String)
    # Coverage shifts statement index of fresh node.
    @test isempty(opened.held) && isa_variant(only(keys(opened.unguarded))[1], Node.Fresh) && only(keys(opened.unguarded))[2] == file
    # Fresh lock that does not escape holds nothing caller sees; `close` releases file caller gets.
    @test isempty(summary_of(lock_local).held) && isempty(summary_of(closed_file, String).held)
    # Lock operand with two targets: Corset cannot count which one holds.
    merged = summary_of(lock_either!, Bool, ReentrantLock, ReentrantLock).held
    @test holds(merged) == Dict((placed(3), lock_) => (0, blind), (placed(4), lock_) => (0, blind)) && all(hold -> hold.reason == RELEASE_PATTERN, values(merged))
    @test holds(summary_of(lock_open!, Any).held) == Dict((placed(2), lock_) => (0, blind))
    # Lock write counts lock resource only; file hold on caller place writes nothing.
    span = Span("fixture.jl", 1, 1, Precision.line)
    file_held = HoldCounts((placed(2), lock_) => HoldCount(1, none, 1, ""), (placed(3), file) => HoldCount(1, none, 1, ""))
    found = Summary(Accesses(), Accesses(), Edges(), Holds(), Holds(), Dict{GlobalRef, Nodes}(), Set{Callback}(), Nodes(), 0, false, false, file_held, HoldCounts(), Dict{Tuple{Node.Type, Resource.T}, Unguarded}())
    writes, blind_writes = Summaries.lock_writes(found, _ -> span, _ -> EffectKind.memory)
    @test shape(writes) == [(parameter(2), false, Confidence.definite)] && only(writes).kind == EffectKind.synchronization && isempty(blind_writes)
    # Semaphore slot counts like lock; `trylock` gives blind spot.
    @test only(values(summary_of(slot_store!, Base.Semaphore, Vector{Int}).unguarded)).hold.count == 1
    tried = summary_of(try_unlock, ReentrantLock)
    @test holds(tried.held) == Dict((placed(2), lock_) => (0, blind)) && only(values(tried.held)).reason == RELEASE_PATTERN
    # Hold count: reason exactly at blind level; count only at none level.
    @test_throws ArgumentError HoldCount(0, blind, 1, "")
    @test_throws ArgumentError HoldCount(0, code, 1, RELEASE_PATTERN)
    @test HoldCount(3, code, 1, "") == HoldCount(0, code, 1, "")
    single, double = HoldCount(1, none, 4, ""), HoldCount(2, none, 2, "")
    # Sum keeps first cause; hold 0 takes cause of change.
    @test plus(single, HoldCount(-1, none, 7, "")) == HoldCount(0, none, 4, "") && plus(ZERO_HOLD, single) == single
    @test join_hold(single, single) == single && join_hold(single, double) == HoldCount(0, code, 2, "")
    @test join_hold(single, HoldCount(0, blind, 9, RELEASE_PATTERN)) == HoldCount(0, blind, 4, RELEASE_PATTERN)
    # Widening: count that differs becomes blind; absent key counts as 0.
    key = (placed(2), lock_)
    @test widen_holds(HoldCounts(key => single), HoldCounts(key => double)) == HoldCounts(key => unsettled(single))
    @test widen_holds(HoldCounts(), HoldCounts(key => double))[key].reason == UNSETTLED
    @test widen_holds(HoldCounts(key => double), HoldCounts(key => double)) == HoldCounts(key => double)
    # Paths: equal counts merge and keep conditions both agree on; path past limit joins all.
    origin = Origin.Caller(parameter(2))
    path(count::Int, conditions::Pair{Symbol, Bool}...)::Path = (Summaries.Counts((origin, lock_) => HoldCount(count, none, 1, "")), Dict{Any, Bool}(conditions...))
    paths = Path[]
    @test add_path!(paths, path(1, :flag => true)) && !add_path!(paths, path(1, :flag => true))
    @test add_path!(paths, path(1, :flag => false)) && last(only(paths)) == Dict{Any, Bool}()
    foreach(count -> add_path!(paths, path(count, :flag => true)), 2:PATH_LIMIT)
    @test length(paths) == PATH_LIMIT
    @test add_path!(paths, path(PATH_LIMIT + 1)) && only(paths)[1][(origin, lock_)].level == code
    # Statement inside scope `enter` without catch block goes to catch block of outer `try`.
    ir = first(only(Base.code_ircode(scoped_sum, (Int,))))
    enters = [index => ir.stmts[index][:stmt].catch_dest for index in 1:length(ir.stmts) if ir.stmts[index][:stmt] isa Core.EnterNode]
    scope, outer = only(first(entry) for entry in enters if last(entry) == 0), only(last(entry) for entry in enters if last(entry) != 0)
    @test Summaries.catch_block(ir, Core.Compiler.compute_trycatch(ir), scope + 1) == outer
end

@testset "release balance facts" begin
    definite, possible, lock_place = Confidence.definite, Confidence.possible, parameter(2, Step.Field(:lock))
    synchronized(found::MethodVerdict)::Vector{Tuple{Place.Type, Bool, Confidence.T}} = shape(filter(access -> access.kind == EffectKind.synchronization, found.writes))
    @test synchronized(named(:grab_guard!)) == [(lock_place, false, definite)]
    @test line_text(only(named(:grab_guard!).writes).cause) == "grab_guard!(guard::Guard)::Nothing = (lock(guard.lock); nothing)"
    @test synchronized(named(:maybe_grab!)) == [(lock_place, false, possible)] && isempty(named(:maybe_grab!).unguarded)
    # Balanced use writes no lock; store that throws while lock is held is F98 fact.
    set = named(:guarded_set!)
    @test isempty(synchronized(set)) && shape(set.writes) == [(parameter(2, Step.Field(:items)), false, definite)]
    hold = only(set.unguarded)
    @test strip(line_text(hold.acquire)) == "lock(guard.lock)" && strip(line_text(hold.throws)) == "guard.items[1] = value"
    @test hold.confidence == definite
    @test strip(line_text(only(named(:guarded_pair_set!).unguarded).throws)) == "guard.items[1] = value"
    @test strip(line_text(only(named(:grab_then_set!).unguarded).acquire)) == "grab_guard!(guard)"
    safe = named(:safe_set!)
    @test isempty(synchronized(safe)) && isempty(safe.unguarded) && isempty(safe.blind_writes)
    # `trylock` gives blind lock write; throw while blind hold gives blind spot, no fact.
    @test blind_shape(named(:try_grab!).blind_writes) == [(lock_place, false, RELEASE_PATTERN)]
    tried = named(:try_set!)
    @test isempty(tried.unguarded) && blind_shape(tried.blind_writes) == [(lock_place, false, RELEASE_PATTERN)]
    @test any(spot -> spot.cause == RELEASE_PATTERN && strip(line_text(spot.span)) == "trylock(guard.lock)", SPOTS)
    # Lock of field that inference widens is lock still.
    @test synchronized(named(:loose_grab!)) == [(parameter(2, Step.Field(:lock)), false, definite)]
    # Lock from task storage: Corset cannot tell which object holds.
    @test (Place.At(Root.Elsewhere(), Step.Type[]), false, RELEASE_PATTERN) in blind_shape(named(:lock_stored).blind_writes)
end

@testset "call facts" begin
    memory_kind, lock_kind = EffectKind.memory, EffectKind.synchronization
    calls_to(name::Symbol, callee::Symbol)::Vector{CallSummary} = [call for call in named(name).calls if any(method -> method.name === callee, something(callee_methods(call.callee), Method[]))]
    # Unit keeps discarded call that compaction deletes: no effect, no throw, terminates.
    dropped = only(calls_to(:drop_calls!, :abs))
    @test !dropped.used && isempty(dropped.kinds) && !dropped.throws && dropped.terminates
    @test strip(line_text(dropped.span)) == "abs(length(values))"
    pushed = only(calls_to(:drop_calls!, :push!))
    @test !pushed.used && pushed.kinds == [memory_kind]
    @test only(calls_to(:drop_calls!, :parse)).throws
    @test [call.used for call in calls_to(:drop_calls!, :length)] == [true, true]
    foreign = only(call for call in named(:drop_calls!).calls if call.callee == Callee.Foreign())
    @test !foreign.used && isempty(foreign.kinds)
    # Builtin, open call, and call that no method matches: it throws.
    odd = named(:odd_calls).calls
    @test any(call -> call.callee == Callee.Builtin(Core.ifelse) && !call.used && isempty(call.kinds) && !call.throws, odd)
    @test any(call -> call.callee == Callee.Open() && !call.used, odd)
    dead = only(call for call in odd if call.callee == Callee.Methods(Method[]))
    @test dead.throws && !dead.used
    # Compaction turns use of constant result into literal; use before compaction counts.
    converts = [call for call in named(:constant_calls).calls if call.callee == Callee.Methods([which(UInt8, Tuple{Char})])]
    @test [(strip(line_text(call.span)), call.used) for call in converts] == [("UInt8('a')", false), ("return byte == UInt8('\\t')", true)]
    # Lock primitive, and callee that leaves lock held: synchronization.
    @test only(calls_to(:grab_guard!, :lock)).kinds == [lock_kind]
    @test only(calls_to(:grab_then_set!, :grab_guard!)).kinds == [lock_kind]
    # Shortcut unit keeps code for call facts; its summary stays empty.
    run = start_run(nothing, Module[])
    plus = Base.method_instance(+, (Int, Int))
    body = unit_body!(run, Core.Compiler.typeinf_frame(run.interpreter, plus, false), false)
    @test body.shortcut
    run.bodies[plus] = body
    root = (plus, Pair{Int, Any}[])
    solve!(run, [root])
    @test same(root_summary!(run, root), empty_summary()) && haskey(run.codes, root)
    added = only(last.(root_calls!(run, root)))
    @test added.callee == Callee.Builtin(Core.Intrinsics.add_int) && added.used && !added.throws && added.terminates
    # Passes empty unreachable set of their state; frame keeps own set, so second body drops dead `convert` too.
    frame = Core.Compiler.typeinf_frame(run.interpreter, Base.method_instance(CASES.add, (Int, Int)), false)
    unreachable = copy(frame.unreachable)
    bodies = [unit_body!(start_run(nothing, Module[]), frame, false) for _ in 1:2]
    @test !isempty(unreachable) && frame.unreachable == unreachable
    @test length(bodies[1].ir.stmts) == length(bodies[2].ir.stmts) && bodies[1].used == bodies[2].used
    # Units of method merge: methods join; other callee pair gives open dispatch.
    span = named(:drop_calls!).site.span
    first_fact = CallSummary(span, Callee.Methods([only(methods(CASES.no_text_method))]), [EffectKind.io], false, true, false)
    second_fact = CallSummary(span, Callee.Methods([only(methods(CASES.take_lock!))]), [memory_kind], true, false, true)
    merged = merge_calls(first_fact, second_fact)
    # Callee methods keep source order whatever order units merge in.
    @test merged.callee == Callee.Methods([only(methods(CASES.take_lock!)), only(methods(CASES.no_text_method))])
    @test merge_calls(second_fact, first_fact).callee == merged.callee
    @test methods_callee([only(methods(CASES.no_text_method)), only(methods(CASES.take_lock!)), only(methods(CASES.no_text_method))]) == merged.callee
    @test merged.kinds == [memory_kind, EffectKind.io] && merged.throws && !merged.terminates && merged.used
    @test merge_callees(Callee.Foreign(), Callee.Foreign()) == Callee.Foreign()
    @test merge_callees(Callee.Foreign(), first_fact.callee) == Callee.Open()
end

@testset "iteration starts" begin
    definite = Confidence.definite
    starts(name::Symbol)::Vector{Tuple{Place.Type, Bool, Confidence.T}} = shape(filter(access -> access.kind == EffectKind.iteration, named(name).reads))
    @test starts(:loop_sum) == [(parameter(2), false, definite)]
    @test strip(line_text(only(filter(access -> access.kind == EffectKind.iteration, named(:loop_sum).reads)).cause)) == "for item in items"
    @test starts(:holder_sum) == [(parameter(2, Step.Field(:items)), false, definite)]
    @test starts(:first_any) == starts(:pair_head) == [(parameter(2), false, definite)]
    @test isempty(starts(:next_item)) && isempty(starts(:no_items)) && isempty(starts(:dead_start))
end

@testset "soundness" begin
    for (method, arguments) in CALLS
        @check max_examples = 20 db = false function observed_writes_covered(drawn = arguments)
            before, globals = deepcopy(drawn), globals_now()
            method(drawn...)
            found = only(found for found in FACTS if found.site.method.name == nameof(method) && Tuple{typeof(method), map(typeof, drawn)...} <: found.site.method.sig)
            changed = [Root.Parameter(position + 1) for position in eachindex(drawn) if !same_state(before[position], drawn[position])]
            moved = [Root.Global(GlobalRef(CASES, name)) for (name, old) in globals if !same_state(old, getglobal(CASES, name))]
            all(root -> covered(found, root), [changed; moved])
        end
    end
end
