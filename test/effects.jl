using Test: @test, @testset, @test_throws
using Corset: Corset
using Corset.Facts: Facts, MethodEffects, Access, BlindAccess, Place, Root, Step, Confidence, BlindSpot, Span, Precision
using Corset.Inference: infer_package, open_journal, records, explicit_any
using Corset.StandIns: FunctionStandIn
using Corset.Signatures: Provenance
using Corset.Effects:
    Effects, Doubt, Level, Sources, BLIND, level_of, sources_of, NO_DOUBT, CODE_DOUBT, BLIND_DOUBT, OPAQUE, INHERENT, LAST_PARAMETER, parameter_source, least, Effect, Summary, Node, Nodes, Origin, Targets, Operand, Outcome, Code, Flow, start_run, solve!, dispatch, body!,
    library_body, journal_key, stronger, most, same, empty_summary, open_summary, referent!, field_step, backing_field, slot_type,
    element_type, constant, start_flow, statement!, map_node, CallSite, cause_span, root_of, resolve, operand_type, access!, add!, deep, worst,
    components, foreign_name, join_accesses!, JOIN_LIMIT, join_limit, widen, UNSETTLED, Accesses, Edges, Holds, null_pointer, field_parameters!, Body, type_sources, caller_doubt, source_provenance,
    Callback, Callees, Variant, root_summary, deferred, parameter_origin
using Supposition: Supposition, Data, @check, @composed
using Moshi.Data: isa_variant

const CASE = joinpath(@__DIR__, "effects", "EffectsCases")

"""
Fixture module, files, package facts, inference units, effects facts and blind spots of `EffectsCases`, loaded with
case on load path.
"""
function case_facts()::Tuple{Module, Vector{Facts.SyntaxFile}, Facts.PackageFacts, Corset.Inference.Units, Facts.EffectsFacts, Vector{BlindSpot}}
    sources = Corset.Discovery.discover(CASE; environment = nothing)
    push!(LOAD_PATH, CASE)
    loaded = try
        Corset.Package.load(sources.project, sources.files)
    finally
        pop!(LOAD_PATH)
    end
    _, _, units, _ = infer_package(loaded.facts, sources.files, nothing, nothing)
    facts, spots = Effects.effects_facts(loaded.facts, units, nothing)
    return first(loaded.facts.modules), sources.files, loaded.facts, units, facts, spots
end

const CASES, FILES, PACKAGE, UNITS, FACTS, SPOTS = case_facts()

"""Place at parameter `position` (1 is called function) and `steps`."""
parameter(position::Int, steps::Step.Type...)::Place.Type = Place.At(Root.Parameter(position), Step.Type[steps...])

"""Place of global `name` of `holder`."""
global_place(holder::Module, name::Symbol)::Place.Type = Place.At(Root.Global(GlobalRef(holder, name)), Step.Type[])

"""Effects of fixture method `name` whose argument types are `types`."""
function effects(name::Symbol, types::Type...)::MethodEffects
    return only(found for found in FACTS.methods if found.site.method.name == name && collect(fieldtypes(found.site.method.sig))[2:end] == collect(types))
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
    @test isempty(effects(:set_deeper!, CASES.Wrapper, Int).writes)
    @test blind_shape(effects(:set_deeper!, CASES.Wrapper, Int).blind_writes) == [(Place.Deep(Root.Parameter(2)), false, "alias")]
    @test blind_shape(effects(:call_deeper!, CASES.Wrapper).blind_writes) == [(Place.Deep(Root.Parameter(2)), false, "alias")]
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
    @test (parameter(3, Step.Element()), false, definite) in shape(effects(:copy_boxes!, Vector{CASES.Box}, Vector{CASES.Box}).writes)
    @test (parameter(3), false, definite) in shape(effects(:remember!, IdDict{Int, CASES.Box}, CASES.Box).writes)
    @test shape(effects(:store_pointer!, Vector{Int}).writes) == [(parameter(2), false, definite)]
    @test blind_shape(effects(:bump_nest!).blind_writes) == [(Place.Deep(Root.Global(GlobalRef(CASES, :NEST))), false, "alias")]
    @test blind_shape(effects(:call_nest!).blind_writes) == [(Place.Deep(Root.Global(GlobalRef(CASES, :NEST))), false, "alias")]
    @test all(found -> found.site.method.name != :fail, FACTS.methods)
    @test BlindSpot("always throws on stand-ins", only(site for site in UNITS.typed if site.site.method.name == :fail).site.span) in SPOTS
    @test any(spot -> spot.cause == "alias", SPOTS)
    @test all(found -> found.complete == !(found.site.method in UNITS.incomplete), FACTS.methods)
end

"""Effects of only fixture method `name`."""
named(name::Symbol)::MethodEffects = only(found for found in FACTS.methods if found.site.method.name == name)

@testset "provenance" begin
    possible, opaque, elsewhere = Confidence.possible, Effects.OPAQUE_DATA, Place.At(Root.Elsewhere(), Step.Type[])
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
    defaulted = only(found for found in FACTS.methods if found.site.method.name == :reset_default! && found.site.method.nargs == 2)
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

"""Doubt of each access of summary `table`."""
doubts(table::Dict{Tuple{Place.Type, Bool}, Effect})::Dict{Tuple{Place.Type, Bool}, Doubt} = Dict(key => effect.doubt for (key, effect) in table)

"""Summary of fixture method `f` on argument `types`, solved as package code, before root resolves its callback records."""
function raw_summary(f::Any, types::Type...)::Summary
    run = start_run(nothing, Module[CASES])
    root = (only(something(dispatch(Any[typeof(f), types...], run.world, 1))), Pair{Int, Any}[])
    solve!(run, [root])
    return run.summaries[root]
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
    @test isempty(raw_summary(CASES.set_pair!, CASES.Box).callbacks)
    # Units split `Union` stand-ins: `Relay` unit resolves record of `Relay` call, then record of `Setter` call inside it.
    setter = Step.Field(:setter)
    @test shape(named(:act_either!).writes) == [(parameter(2, box), false, definite), (parameter(2, setter, box), false, definite)]
    # Join resolves records of its members: each member writes its own place, so each write is `possible`.
    either = raw_summary(CASES.act_either!, Union{CASES.Setter, CASES.Relay}, Int)
    @test doubts(either.writes) == Dict((parameter(2, box), false) => CODE_DOUBT, (parameter(2, setter, box), false) => CODE_DOUBT)
    @test isempty(either.callbacks)
    # Cycle member that resolves record of other member reads its summary, so it reruns when that summary changes.
    @test shape(named(:restart!).writes) == [(parameter(2), false, definite), (parameter(3), false, definite)]
    # Record of earlier round goes when callable grows to fresh object: call resolves here.
    @test isempty(raw_summary(CASES.pick_setter!, CASES.Setter, Int).callbacks)
    @test shape(named(:pick_setter!).writes) == [(parameter(2, box), false, definite)]
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
    @test root_summary(run, root) === run.summaries[root]
end

@testset "engine stage" begin
    @test Corset.Engine.effects_facts(PACKAGE, UNITS, false, nothing) == (nothing, BlindSpot[])
    @test Corset.Engine.effects_facts(nothing, UNITS, true, nothing) == (nothing, BlindSpot[])
    facts, spots = Corset.Engine.effects_facts(PACKAGE, UNITS, true, nothing)
    @test [found.site for found in facts.methods] == [found.site for found in FACTS.methods] && spots == SPOTS
    mktempdir(@__DIR__) do directory
        journaled, _ = Corset.Engine.effects_facts(PACKAGE, UNITS, true, directory)
        @test length(journaled.methods) == length(FACTS.methods)
        @test any(record -> startswith(record.key, "effects\n") && !record.finished, records(directory))
    end
end

"""Summary of method `f` on argument `types`, solved with every instance it reaches."""
function summary_of(f::Any, types::Type...)::Summary
    run = start_run(nothing, Module[])
    root = (only(something(dispatch(Any[typeof(f), types...], run.world, 1))), Pair{Int, Any}[])
    solve!(run, [root])
    return root_summary(run, root)
end

"""Unknown-slot contents of only exported node of `summary`, which must be fresh; coverage shifts its statement index."""
function fresh_spread(summary::Summary)::Nodes
    holder, nodes = only(summary.spread)
    @test isa_variant(holder, Node.Fresh)
    return nodes
end

"""`code` doubt from open types of parameters at `positions`."""
sourced(positions::Int...)::Doubt = Doubt(Level.code, reduce(|, map(parameter_source, positions)))

"""Place at parameter `position` with no steps, as summary keys hold it."""
top(position::Int)::Tuple{Place.Type, Bool} = (parameter(position), false)

const ANY_REF = Ref{Any}(nothing)
const HOLDER = Ref([1])
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
llvm(pointer::Ptr{Int}) = Base.llvmcall("ret ptr %0", Ptr{Int}, Tuple{Ptr{Int}}, pointer)
global_pointer() = cglobal(:jl_n_threads, Cint)
# Library tuple stays nested constant expression in IR.
library_pointer() = cglobal((:jl_n_threads, "libjulia-internal"), Cint)
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
invoke_open(values::Vector{Int}, selector::Type) = invoke(push!, selector, values, 1)
invoke_missing(values::Vector{Int}) = invoke(push!, Tuple{Int}, values)
spread!(values::Vector{Int}, more::Tuple{Int, Int}) = push!(values, more...)
spread_rest!(values::Vector{Int}, more::Tuple{Vararg{Int}}) = push!(values, more...)
nested_spread!(values::Vector{Int}, more::Tuple{Tuple{Int}}) = push!(values, more[1]...)
dynamic!(container::Any) = sort!(container)
nested_apply(values::Vector{Int}, more::Tuple{Tuple{Int}}) = Core._apply_iterate(iterate, Core._apply_iterate, (iterate, push!, values), more)
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
object_at(pointer::Ptr{Cvoid}) = unsafe_pointer_to_objref(pointer)
unknown_foreign!(pointer::Ptr{Int}) = ccall(:corset_unknown_function, Cvoid, (Ptr{Int},), pointer)
unknown_foreign_object!(x::Any) = ccall(:corset_unknown_function, Cvoid, (Any,), x)
popped(table::IdDict{Int, Vector{Int}}) = pop!(table, 1)
no_method(values::Vector{Int}) = sin(values)

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

@testset "builtin transfer" begin
    none, code, blind = NO_DOUBT, CODE_DOUBT, BLIND_DOUBT
    swapped = summary_of(swap_field!, Base.RefValue{Vector{Int}}, Vector{Int})
    @test doubts(swapped.writes) == Dict(top(2) => none) && doubts(swapped.reads) == Dict(top(2) => none)
    # Heap is flow-insensitive: old content holds stored value too.
    @test swapped.result == Nodes(Node.Placed(parameter(2, Step.Field(:x))) => none, Node.Placed(parameter(3)) => none)
    @test doubts(summary_of(modify_field!, Base.RefValue{Int}).writes) == Dict(top(2) => none)
    closure = summary_of(modify_closure!, Base.RefValue{Vector{Int}}, Vector{Int})
    @test closure.writes[(parameter(2, Step.Field(:x)), true)].doubt == code
    @test closure.writes[(parameter(3), true)].doubt == code
    @test haskey(summary_of(replace_field!, Base.RefValue{Vector{Int}}, Vector{Int}).edges, (Node.Placed(parameter(2)), Step.Field(:x)))
    @test doubts(summary_of(once_field!, Base.RefValue{Vector{Int}}, Vector{Int}).writes) == Dict(top(2) => none)
    named = summary_of(named_field!, Base.RefValue{Vector{Int}}, Symbol, Vector{Int})
    @test named.spread == Dict(Node.Placed(parameter(2)) => Nodes(Node.Placed(parameter(4)) => none))
    @test named.result[Node.Placed(Place.Deep(Root.Parameter(2)))] == blind
    here = @__MODULE__
    rebound = summary_of(rebind!, Vector{Int})
    @test doubts(rebound.writes) == Dict((global_place(here, :slot), false) => none, top(2) => none)
    @test rebound.bound == Dict(GlobalRef(here, :slot) => Nodes(Node.Placed(parameter(2)) => none))
    @test summary_of(swap_global!, Vector{Int}).result == Nodes(Node.Placed(global_place(here, :slot)) => none, Node.Placed(parameter(2)) => none)
    @test doubts(summary_of(modify_global!).writes) == Dict((global_place(here, :tally), false) => none)
    @test haskey(summary_of(replace_global!, Vector{Int}).writes, (global_place(here, :slot), false))
    @test haskey(summary_of(once_global!, Vector{Int}).writes, (global_place(here, :loose), false))
    named_global = summary_of(set_named!, Module, Symbol, Vector{Int})
    @test doubts(named_global.writes) == Dict((Place.At(Root.Elsewhere(), Step.Type[]), false) => code)
    @test named_global.spread == Dict(Node.Outside() => Nodes(Node.Placed(parameter(4)) => code))
    @test summary_of(get_named, Module, Symbol).result == Nodes(Node.Outside() => code)
    @test summary_of(get_slot).result == Nodes(Node.Placed(global_place(here, :slot)) => none)
    @test isempty(summary_of(read_holder).reads[(global_place(here, :HOLDER), false)].reason)
    @test doubts(summary_of(memory_get, Memory{Vector{Int}}).reads) == Dict(top(2) => none)
    @test summary_of(memory_get, Memory{Vector{Int}}).result == Nodes(Node.Placed(parameter(2, Step.Element())) => none)
    for writer in (memory_once!, memory_swap!, memory_modify!, memory_replace!)
        @test summary_of(writer, Memory{Vector{Int}}, Vector{Int}).writes[top(2)].doubt == none
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
        @test summary_of(writer, Ptr{Int}).writes[top(2)].doubt == none
    end
    @test doubts(summary_of(pointer_get, Ptr{Int}).reads) == Dict(top(2) => none)
    @test summary_of(llvm, Ptr{Int}).result == Nodes(Node.Placed(parameter(2)) => code, Node.Outside() => code)
    @test summary_of(llvm, Ptr{Int}).writes[(parameter(2), true)].doubt == code
    @test summary_of(global_pointer).result == Nodes(Node.Outside() => code)
    @test summary_of(library_pointer).result == Nodes(Node.Outside() => code)
    # Null pointer global points into no object, so `Cstring` error path writes no `C_NULL`.
    @test all(((place, _),) -> root_of(place) != Root.Global(GlobalRef(Base, :C_NULL)), keys(summary_of(length_of, String).writes))
    @test null_pointer(GlobalRef(Base, :C_NULL)) && !null_pointer(GlobalRef(@__MODULE__, :HOLDER)) && !null_pointer(GlobalRef(@__MODULE__, :slot))
    @test summary_of(object_at, Ptr{Cvoid}).result == Nodes(Node.Placed(parameter(2)) => none)
    @test doubts(summary_of(unknown_foreign!, Ptr{Int}).writes) == Dict((parameter(2), true) => code)
    # Unknown C function: doubt in code, also on argument of open type.
    @test doubts(summary_of(unknown_foreign_object!, Any).writes) == Dict((parameter(2), true) => code)
    popped_summary = summary_of(popped, IdDict{Int, Vector{Int}})
    @test doubts(popped_summary.writes) == Dict(top(2) => none) && popped_summary.result == Nodes(Node.Placed(parameter(2, Step.Element())) => none)
    for (target, name) in ((QuoteNode(:strlen), :strlen), (Expr(:tuple, QuoteNode(:f), "lib"), :f), ((:f, "lib"), :f), ("f", :f), (Expr(:tuple), nothing), ((), nothing), (1, nothing))
        @test foreign_name(target) === name
    end
end

@testset "statements and calls" begin
    none, code, blind = NO_DOUBT, CODE_DOUBT, BLIND_DOUBT
    @test fresh_spread(summary_of(quoted, Vector{Int})) == Nodes(Node.Placed(parameter(2)) => none)
    @test fresh_spread(summary_of(call_quoted, Vector{Int})) == Nodes(Node.Placed(parameter(2)) => none)
    @test any(nodes -> haskey(nodes, Node.Placed(parameter(2))), values(summary_of(opaque, Vector{Int}).spread))
    @test Node.Placed(parameter(2)) in keys(only(values(summary_of(splat, Vector{Int}).edges)))
    @test fresh_spread(summary_of(splat_vararg, Tuple{Vararg{Vector{Int}}})) == Nodes(Node.Placed(Place.Deep(Root.Parameter(2))) => blind)
    caught_summary = summary_of(caught, Vector{Int})
    @test any(nodes -> haskey(nodes, Node.Outside()), values(caught_summary.edges))
    for (pusher, types) in ((latest!, (Vector{Int},)), (world!, (Vector{Int},)), (invoked!, (Vector{Int},)), (spread!, (Vector{Int}, Tuple{Int, Int})), (nested_spread!, (Vector{Int}, Tuple{Tuple{Int}})))
        @test summary_of(pusher, types...).writes[top(2)].doubt == none
    end
    @test isempty(summary_of(invoke_dead, String).writes)
    @test summary_of(invoke_open, Vector{Int}, Type).writes[(parameter(2), true)].doubt == code
    @test summary_of(invoke_missing, Vector{Int}).writes[(parameter(2), true)].doubt == code
    # Tuple of unknown length dispatches on `Vararg`: `push!` contract writes `values` only.
    @test doubts(summary_of(spread_rest!, Vector{Int}, Tuple{Vararg{Int}}).writes) == Dict(top(2) => none)
    # Open dispatch on `::Any` argument: its type is source of doubt, so caller provenance decides.
    @test summary_of(dynamic!, Any).writes[(parameter(2), true)].doubt == sourced(2)
    # No method matches: call throws, so it writes and reads nothing.
    @test isempty(summary_of(no_method, Vector{Int}).writes) && isempty(summary_of(no_method, Vector{Int}).reads)
    @test summary_of(nested_apply, Vector{Int}, Tuple{Tuple{Int}}).writes[(parameter(2), true)].doubt == code
    @test summary_of(embedded).result == Nodes(Node.Outside() => code)
    @test summary_of(unknown_field, Module, Symbol).result == Nodes(Node.Outside() => code)
    @test summary_of(unknown_any, Module, Symbol, Symbol).result == Nodes(Node.Outside() => code)
    @test haskey(summary_of(first_of_fresh, Vector{Int}).result, Node.Placed(parameter(2)))
    @test haskey(summary_of(any_of_fresh, Vector{Int}, Symbol).result, Node.Placed(parameter(2)))
    @test summary_of(field_global).result == Nodes(Node.Placed(global_place(@__MODULE__, :slot)) => none)
    @test summary_of(make_backed, Vector{Int}).result == Nodes(Node.Placed(parameter(2)) => none)
    run = start_run(nothing, Module[])
    instance = only(something(dispatch(Any[typeof(broken), Int], run.world, 1)))
    @test library_body(run, instance) == "inference gave no code"
    @test summary_of(calls_broken, Vector{Int}).writes == Dict()
    broken_int = summary_of(x -> broken(x), Int)
    @test isempty(broken_int.writes)
    # Phi joins both branches; fresh objects escape through globals and caller objects.
    @test doubts(summary_of(pick!, Vector{Int}, Vector{Int}, Bool).writes) == Dict(top(2) => none, top(3) => none)
    @test summary_of(held_write!, Vector{Int}).writes[top(2)].doubt == none
    @test summary_of(nest_write!, Base.RefValue{Base.RefValue{Vector{Int}}}, Vector{Int}).writes[top(3)].doubt == none
    # Callee access below fresh wrapper reaches caller object inside; open result keeps source of open callee.
    @test summary_of(open_wrapped!, Any, Vector{Int}).writes[(parameter(3), true)].doubt == sourced(2)
    @test summary_of(open_result_write!, Any, Vector{Int}).writes[top(3)].doubt == sourced(2)
    # Callee source maps to caller argument in its position: effects, result nodes and unknown objects alike.
    swapped = summary_of(open_result_swapped, Vector{Int}, Any)
    @test doubts(swapped.writes) == Dict((parameter(2), true) => sourced(3), (parameter(3), true) => sourced(3))
    @test swapped.result == Nodes(Node.Placed(parameter(2)) => sourced(3), Node.Placed(parameter(3)) => sourced(3), Node.Outside() => sourced(3))
    @test summary_of(open_unknown_through!, Any, Any).writes[(Place.At(Root.Elsewhere(), Step.Type[]), true)].doubt == sourced(3)
    @test summary_of(open_loaded!, Any).writes[(Place.At(Root.Elsewhere(), Step.Type[]), true)].doubt == sourced(2)
    @test summary_of(open_loaded_any!, Any, Symbol).writes[(Place.At(Root.Elsewhere(), Step.Type[]), true)].doubt == sourced(2)
    # Function stand-in stands for any callee Corset chose: its call stays open, with or without keywords.
    @test summary_of(open_on!, FunctionStandIn, Vector{Int}).writes[(parameter(3), true)].doubt == Doubt(Level.code, OPAQUE)
    @test summary_of(open_keywords!, FunctionStandIn, Vector{Int}).writes[(parameter(3), true)].doubt == Doubt(Level.code, OPAQUE)
    @test all(((place, _),) -> root_of(place) != Root.Parameter(3), keys(summary_of(open_element!, Any, Vector{Int}).writes))
    mktempdir(@__DIR__) do directory
        journal = open_journal(directory)
        try
            target = only(something(dispatch(Any[typeof(push!), Vector{Int}, Int], run.world, 1)))
            push!(journal.crashed, journal_key(target))
            crashed = start_run(journal, Module[])
            root = (only(something(dispatch(Any[typeof(latest!), Vector{Int}], crashed.world, 1))), Pair{Int, Any}[])
            solve!(crashed, [root])
            effect = crashed.summaries[root].writes[(parameter(2), true)]
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
    @test doubts(summary_of(element_write!, Any).writes) == Dict((parameter(2, Step.Element()), false) => none, top(2) => code)
    # Argument that admits consumed iterator (`Iterators.Stateful`) gets `possible` write.
    @test doubts(summary_of(iterated, Any).writes) == Dict(top(2) => code)
    @test doubts(summary_of(contains_any, Any, Any).writes) == Dict(top(3) => code)
    @test doubts(summary_of(appended!, Vector{Int}, Any).writes) == Dict(top(2) => none, top(3) => code)
    # First argument that may be callable selects callback form: call stays open.
    @test doubts(summary_of(merged_any!, Any, Any).writes) == Dict((parameter(2), true) => sourced(2, 3), (parameter(3), true) => sourced(2, 3))
    @test doubts(summary_of(got, Any, Int).writes) == Dict((parameter(2), true) => sourced(2))
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
    @test doubts(summary_of(spread_rest_first!, Vector{Int}, Vector{Vector{Int}}).writes) == Dict(top(2) => none, (parameter(3, Step.Element()), false) => none)
    # Operand after spread of unknown length has unknown position too.
    @test doubts(summary_of(spread_then!, Vector{Vector{Int}}, Vector{Int}).writes) == Dict((parameter(2, Step.Element()), false) => none, top(3) => none)
    # Caller tuple slot of unknown position collapses: blind.
    @test doubts(summary_of(spread_tuple!, Tuple{Vararg{Vector{Int}}}).writes) == Dict((Place.Deep(Root.Parameter(2)), false) => blind)
    # Spread callee stays open: method table matches builtin method `setfield!(...)` for `Vararg` callee.
    @test doubts(summary_of(spread_builtin_callee, Vector{typeof(setfield!)}).writes) == Dict((parameter(2, Step.Element()), true) => code)
    @test fresh_spread(summary_of(spread_packed, Vector{Vector{Int}})) == Nodes(Node.Placed(parameter(2, Step.Element())) => none)
    # Contract holds when spread falls on its vararg role.
    pushed = summary_of(spread_pushed!, Vector{Vector{Int}}, Vector{Vector{Int}})
    @test doubts(pushed.writes) == Dict(top(2) => none) && pushed.edges[(Node.Placed(parameter(2)), Step.Element())] == Nodes(Node.Placed(parameter(3, Step.Element())) => none)
    # Spread before contract role, into builtin, as callee, or of collection with own `iterate`: open.
    # Open call takes spread elements, not array itself.
    @test doubts(summary_of(spread_set!, Vector{Int}, Vector{Int}).writes) == Dict((parameter(2), true) => code, (parameter(3, Step.Element()), true) => code)
    # Builtin of unknown argument count: doubt in code. Spread callee: element type decides.
    @test doubts(summary_of(spread_field, Vector{Any}).writes) == Dict((parameter(2, Step.Element()), true) => code)
    @test doubts(summary_of(spread_latest, Vector{Any}).writes) == Dict((parameter(2, Step.Element()), true) => sourced(2))
    @test doubts(summary_of(spread_set_max, Set{Vector{Int}}).writes) == Dict((parameter(2), true) => code)
end

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
    @test opened.writes[(parameter(2), true)] == Effect(BLIND_DOUBT, 0, "cause") && opened.result[Node.Outside()] == BLIND_DOUBT
    cache = IdDict{Any, Bool}()
    @test !referent!(cache, Union{}) && referent!(cache, Union{Int, Vector{Int}}) && !referent!(cache, Union{Int, Symbol})
    @test referent!(cache, AbstractVector) && !referent!(cache, Type{Int}) && referent!(cache, Ptr{Int})
    @test !referent!(cache, Tuple{Int, Symbol}) && referent!(cache, Tuple{Int, Vector{Int}}) && !referent!(cache, Module)
    @test field_step(Tuple{Int}, :a) === nothing && field_step(Tuple{Int}, 1) == Step.Position(1)
    @test field_step(Base.RefValue{Int}, 1) == Step.Field(:x) && field_step(Base.RefValue, 1) == Step.Position(1)
    @test field_step(Base.RefValue{Int}, 1.0) === nothing
    @test backing_field(Vector{Int}, :ref) && !backing_field(Vector{Int}, :nope) && !backing_field(Vector{Int}, 9)
    @test !backing_field(Tuple{Memory{Int}}, 1) && !backing_field(Vector{Int}, :size)
    @test slot_type(Base.RefValue{Int}, nothing) == Any && slot_type(Base.RefValue{Int}, Some{Any}(:x)) == Int
    @test slot_type(Base.RefValue{Int}, Some{Any}(:nope)) == Any && slot_type(AbstractVector, Some{Any}(1)) == Any
    @test element_type(Ptr{Int}) == Int && element_type(Vector{Int}) == Any && element_type(Union{Int, Ptr{Int}}) == Any
    @test element_type(MemoryRef{Vector{Int}}) == Vector{Int}
    @test root_of(Place.Deep(Root.Elsewhere())) == Root.Elsewhere()
    targets = Targets(Origin.Unknown() => CODE_DOUBT)
    @test !add!(targets, Origin.Unknown(), BLIND_DOUBT) && add!(targets, Origin.Unknown(), NO_DOUBT)
    table = Dict{Tuple{Origin.Type, Bool}, Effect}()
    access!(table, Targets(Origin.Allocation(1) => BLIND_DOUBT), false, Effect(BLIND_DOUBT, 4, "cause"))
    @test table[(Origin.Allocation(1), false)] == Effect(BLIND_DOUBT, 4, "cause")
    run = start_run(nothing, Module[])
    instance = only(something(dispatch(Any[typeof(fill_one!), Vector{Int}], run.world, 1)))
    solve!(run, [(instance, Pair{Int, Any}[])])
    code = run.codes[(instance, Pair{Int, Any}[])]
    @test constant(code.ir, GlobalRef(Base, :nothing)) == Some(nothing)
    @test operand_type(code.ir, Operand.Part(Core.Argument(2), 1)) == MemoryRef{Int}
    flow = start_flow(code.ir, code.outcomes, run.referent, false)
    @test_throws ArgumentError statement!(flow, 1, Expr(:unknown_head), Callees(Vector{Variant}[], Dict{Variant, Summary}(), Set{Variant}()))
    @test_throws ArgumentError statement!(flow, 1, QuoteNode(:literal), Callees(Vector{Variant}[], Dict{Variant, Summary}(), Set{Variant}()))
    @test map_node(flow, Node.Fresh(4), CallSite(Targets[], 7, 2, Dict{Place.Type, Targets}(), Dict{Int, Sources}())) == Targets(Origin.Allocation(7) => BLIND_DOUBT)
    @test deep(flow, Targets(Origin.Caller(parameter(2)) => NO_DOUBT)) == Targets(Origin.Caller(Place.Deep(Root.Parameter(2))) => BLIND_DOUBT)
    # Type sources: parameter of caller place, sources of chain; global and merge of fresh objects are doubt in code.
    held_global = Origin.Caller(global_place(@__MODULE__, :HOLDER))
    @test type_sources(flow, Targets(Origin.Unknown() => sourced(3))) == parameter_source(3)
    @test type_sources(flow, Targets(held_global => NO_DOUBT, Origin.Caller(parameter(2)) => NO_DOUBT)) == INHERENT | parameter_source(2)
    flow.heap[Origin.Allocation(1)] = Dict(Step.Field(:x) => Targets(Origin.Caller(parameter(2)) => NO_DOUBT))
    @test type_sources(flow, Targets(Origin.Allocation(1) => NO_DOUBT)) == parameter_source(2)
    @test type_sources(flow, Targets(Origin.Allocation(1) => NO_DOUBT, Origin.Allocation(2) => NO_DOUBT)) == INHERENT
    # Callee parameter source becomes type sources of argument; parameter without argument is doubt in code.
    site = CallSite([Targets(), Targets(Origin.Caller(parameter(4)) => NO_DOUBT)], 7, 0, Dict{Place.Type, Targets}(), Dict{Int, Sources}())
    @test caller_doubt(flow, site, sourced(2)) == sourced(4) && caller_doubt(flow, site, sourced(3)) == CODE_DOUBT
    # Source past unit arguments is doubt in code.
    @test source_provenance(parameter_source(3), [Provenance.code, Provenance.opaque]) == Provenance.code
    # Spread part as callee: `MemoryRef` has no call method, so call throws.
    @test isa_variant(resolve(code.ir, Operand.Type[Operand.Part(Core.Argument(2), 1)], run.world, 1), Outcome.Dead)
    typed = only(unit for unit in UNITS.typed if unit.site.method.name == :add)
    @test cause_span(typed, code, 0) == typed.site.span
    shared, partial = (Origin.Allocation(1), false), (Origin.Allocation(2), false)
    joined = Dict(partial => Effect(NO_DOUBT, 1, ""))
    join_accesses!(joined, [Dict(shared => Effect(NO_DOUBT, 5, ""), partial => Effect(CODE_DOUBT, 5, "")), Dict(shared => Effect(BLIND_DOUBT, 5, "alias"))])
    @test joined == Dict(shared => Effect(BLIND_DOUBT, 5, "alias"), partial => Effect(NO_DOUBT, 1, ""))
    joined = Dict{Tuple{Origin.Type, Bool}, Effect}()
    join_accesses!(joined, [Dict(partial => Effect(NO_DOUBT, 5, "")), Dict{Tuple{Origin.Type, Bool}, Effect}()])
    @test joined == Dict(partial => Effect(CODE_DOUBT, 5, ""))
    # Members with `code` doubt from different sources: join keeps sources of all.
    joined = Dict{Tuple{Origin.Type, Bool}, Effect}()
    join_accesses!(joined, [Dict(shared => Effect(sourced(2), 5, "")), Dict(shared => Effect(sourced(3), 6, ""))])
    @test joined == Dict(shared => Effect(sourced(2, 3), 5, ""))
    # Join must reach every call native inference resolves.
    @test JOIN_LIMIT >= Effects.CC.InferenceParams().max_methods
    world = Base.get_world_counter()
    @test length(something(dispatch(Any[typeof(three_way), Any], world, JOIN_LIMIT))) == JOIN_LIMIT
    @test isnothing(dispatch(Any[typeof(four_way), Any], world, JOIN_LIMIT))
    # Package code joins; library code keeps run-time dispatch open.
    @test isnothing(dispatch(Any[typeof(three_way), Any], world, 1))
    package_run = start_run(nothing, [@__MODULE__])
    @test join_limit(package_run, only(something(dispatch(Any[typeof(three_way), Int], world, 1)))) == JOIN_LIMIT
    @test join_limit(package_run, only(something(dispatch(Any[typeof(push!), Vector{Int}, Int], world, 1)))) == 1
    possible_first = Access(parameter(2), false, Confidence.possible, typed.site.span)
    @test worst([possible_first, Access(parameter(2), false, Confidence.definite, typed.site.span)])[1].confidence == Confidence.definite
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
covered(found::MethodEffects, root::Root.Type)::Bool = any(access -> root_of(access.place) == root, [found.writes; found.blind_writes])

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

"""Link of synthetic call chain: each specialization stands for one instance."""
chain_link(x::Any) = x

@testset "slot-name parameters" begin
    run = start_run(nothing, Module[])
    instance = only(something(dispatch(Any[typeof(fill_one!), Vector{Int}], run.world, 1)))
    solve!(run, [(instance, Pair{Int, Any}[])])
    ir = run.codes[(instance, Pair{Int, Any}[])].ir
    # Chain of 10^5 calls: explicit stack keeps deep call chains off native stack.
    links = [Effects.CC.specialize_method(only(methods(chain_link)), Tuple{typeof(chain_link), Val{position}}, Core.svec()) for position in 1:100_000]
    argument = Operand.Value(Core.Argument(2))
    for (position, link) in enumerate(links)
        outcome = position == length(links) ? Outcome.Builtin(Core.getfield, [argument, Operand.Value(QuoteNode(:a))]) : Outcome.Dispatch([links[position + 1]], [Operand.Value(chain_link), argument])
        run.bodies[link] = Body(ir, Int[], Union{Nothing, Outcome.Type}[outcome])
    end
    @test field_parameters!(run, first(links)) == Set([2])
end

"""Wrapper whose type grows at each recursion step."""
struct Layer{T}
    inner::T
end

deepen(x::Any, n::Int) = n == 0 ? x : deepen(Layer(x), n - 1)
deepen_odd(x::Any, n::Int) = n == 0 ? x : deepen_even(Layer(x), n - 1)
deepen_even(x::Any, n::Int) = n == 0 ? x : deepen_odd(Layer(x), n - 1)

"""Steps layer content `Int`, `Float64`, `Float32`: signature changes at each step but never grows."""
retag(x::Any, n::Int) = n == 0 ? x : retag(Layer(narrow(x.inner)), n - 1)
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

peel(f::Any, shell::OuterShell) = peel(f ∘ identity, shell.inner)
peel(f::Any, shell::InnerShell) = peel(f ∘ identity, shell.inner)

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
const ACCESSES = Data.Dicts(Data.SampledFrom([(parameter(2), false), (parameter(2), true), (parameter(3), false)]), EFFECTS; max_size = 3)
const NODES = Data.Dicts(Data.SampledFrom([Node.Placed(parameter(2)), Node.Fresh(1), Node.Outside()]), DOUBTS; max_size = 3)

"""Whether `first` doubts at most as `second` does: lower level, or same level with every source of `second`."""
at_most(first::Doubt, second::Doubt)::Bool = level_of(first) < level_of(second) || level_of(first) == level_of(second) && sources_of(first) & sources_of(second) == sources_of(second)

"""Summaries over two parameters: few places, nodes and causes, so draws overlap."""
const SUMMARIES = @composed function summaries(writes = ACCESSES, reads = ACCESSES, held = NODES, result = NODES, fresh = Data.Integers(0, 2), closed = Data.Booleans())
    edges = isempty(held) ? Edges() : Edges((Node.Placed(parameter(2)), Step.Element()) => held)
    bound = isempty(held) ? Dict{GlobalRef, Nodes}() : Dict(GlobalRef(Main, :slot) => held)
    return Summary(writes, reads, edges, Holds(Node.Fresh(1) => held), Holds(), bound, Set{Callback}(), result, fresh, closed)
end

@testset "call cycle widening" begin
    old = Summary(Accesses((parameter(2), false) => Effect(NO_DOUBT, 3, "")), Accesses(), Edges(), Holds(), Holds(), Dict{GlobalRef, Nodes}(), Set{Callback}(), Nodes(), 1, false)
    new = Summary(Accesses((parameter(2), false) => Effect(CODE_DOUBT, 2, "")), Accesses(), Edges(), Holds(), Holds(), Dict{GlobalRef, Nodes}(), Set{Callback}(), Nodes(), 0, true)
    widened = widen(old, new)
    @test widened.writes == Accesses((parameter(2), false) => Effect(BLIND_DOUBT, 3, UNSETTLED))
    @test widened.fresh == 1 && widened.closed_world
    # Callback records of both summaries stay.
    instance = only(something(dispatch(Any[typeof(CASES.set_value!), CASES.Box, Int], Base.get_world_counter(), 1)))
    record = Callback((variant = (instance, Pair{Int, Any}[]), parameters = [Nodes(Node.Placed(parameter(2)) => NO_DOUBT)]))
    recorded = Summary(Accesses(), Accesses(), Edges(), Holds(), Holds(), Dict{GlobalRef, Nodes}(), Set([record]), Nodes(), 0, false)
    @test widen(recorded, new).callbacks == Set([record]) && widen(new, recorded).callbacks == Set([record])
    @check max_examples = 300 db = false function widen_grows(old = SUMMARIES, new = SUMMARIES)
        widened = widen(old, new)
        kept = all(issubset(keys(getfield(summary, name)), keys(getfield(widened, name))) for summary in (old, new), name in (:writes, :reads, :result))
        # Least doubt per node: level never rises; `code` sources only grow.
        certain = all(at_most(widened.result[node], doubt) for summary in (old, new) for (node, doubt) in summary.result)
        same(widen(widened, new), widened) && kept && certain && widened.fresh >= max(old.fresh, new.fresh)
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

@testset "soundness" begin
    for (method, arguments) in CALLS
        @check max_examples = 20 db = false function observed_writes_covered(drawn = arguments)
            before, globals = deepcopy(drawn), globals_now()
            method(drawn...)
            found = only(found for found in FACTS.methods if found.site.method.name == nameof(method) && Tuple{typeof(method), map(typeof, drawn)...} <: found.site.method.sig)
            changed = [Root.Parameter(position + 1) for position in eachindex(drawn) if !same_state(before[position], drawn[position])]
            moved = [Root.Global(GlobalRef(CASES, name)) for (name, old) in globals if !same_state(old, getglobal(CASES, name))]
            all(root -> covered(found, root), [changed; moved])
        end
    end
end
