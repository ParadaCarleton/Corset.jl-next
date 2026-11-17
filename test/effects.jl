using Test: @test, @testset, @test_throws
using Corset: Corset
using Corset.Facts: Facts, MethodEffects, Access, BlindAccess, Place, Root, Step, Confidence, BlindSpot, Span, Precision
using Corset.Inference: infer_package, open_journal, records
using Corset.Effects:
    Effects, Doubt, Effect, Summary, Node, Nodes, Origin, Targets, Operand, Outcome, Code, Flow, start_run, solve!, dispatch, body!,
    library_body, journal_key, stronger, most, same, empty_summary, open_summary, referent!, field_step, backing_field, slot_type,
    element_type, constant, start_flow, statement!, map_node, cause_span, root_of, resolve, operand_type, access!, add!, deep, worst
using Supposition: Supposition, Data, @check
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
    for name in (:countdown!, :ping!, :pong!)
        @test shape(effects(name, CASES.Box, Int).writes) == [(parameter(2), false, definite)]
    end
    @test shape(effects(:increment!, CASES.Counter).writes) == [(parameter(2), false, definite)]
    @test shape(effects(:swap_count!, CASES.Counter, Int).writes) == [(parameter(2), false, definite)]
    @test shape(effects(:touch!, CASES.Box).writes) == [(parameter(2), false, definite)]
    @test isempty(effects(:touch!, String).writes)
    @test shape(effects(:poke!, CASES.Loose).writes) == [(parameter(2, content), true, possible)]
    @test shape(effects(:store_pointer!, Vector{Int}).writes) == [(parameter(2), false, definite)]
    @test blind_shape(effects(:bump_nest!).blind_writes) == [(Place.Deep(Root.Global(GlobalRef(CASES, :NEST))), false, "alias")]
    @test blind_shape(effects(:call_nest!).blind_writes) == [(Place.Deep(Root.Global(GlobalRef(CASES, :NEST))), false, "alias")]
    @test all(found -> found.site.method.name != :fail, FACTS.methods)
    @test BlindSpot("always throws on stand-ins", only(site for site in UNITS.typed if site.site.method.name == :fail).site.span) in SPOTS
    @test any(spot -> spot.cause == "alias", SPOTS)
    @test all(found -> found.complete == !(found.site.method in UNITS.incomplete), FACTS.methods)
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
    run = start_run(nothing)
    root = (something(dispatch(Any[typeof(f), types...], run.world)), Pair{Int, Any}[])
    solve!(run, [root])
    return run.summaries[root]
end

"""Doubt of each access of summary `table`."""
doubts(table::Dict{Tuple{Place.Type, Bool}, Effect})::Dict{Tuple{Place.Type, Bool}, Doubt.T} = Dict(key => effect.doubt for (key, effect) in table)

"""Place at parameter `position` with no steps, as summary keys hold it."""
top(position::Int)::Tuple{Place.Type, Bool} = (parameter(position), false)

const ANY_REF = Ref{Any}(nothing)
const HOLDER = Ref([1])
global slot::Vector{Int} = [1]
global count::Int = 0
global loose::Any = nothing

swap_field!(cell::Base.RefValue{Vector{Int}}, values::Vector{Int}) = Core.swapfield!(cell, :x, values)
modify_field!(cell::Base.RefValue{Int}) = Core.modifyfield!(cell, :x, +, 1)
modify_closure!(cell::Base.RefValue{Vector{Int}}, values::Vector{Int}) = Core.modifyfield!(cell, :x, (old, new) -> (push!(old, 1); new), values)
replace_field!(cell::Base.RefValue{Vector{Int}}, values::Vector{Int}) = Core.replacefield!(cell, :x, values, values)
once_field!(cell::Base.RefValue{Vector{Int}}, values::Vector{Int}) = Core.setfieldonce!(cell, :x, values)
named_field!(cell::Base.RefValue{Vector{Int}}, name::Symbol, values::Vector{Int}) = (Core.setfield!(cell, name, values); getfield(cell, name))
rebind!(values::Vector{Int}) = (global slot = values; slot[1] = 2; nothing)
swap_global!(values::Vector{Int}) = Core.swapglobal!(@__MODULE__, :slot, values)
modify_global!() = Core.modifyglobal!(@__MODULE__, :count, +, 1)
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
splat(values::Vector{Int}) = NamedTuple{(:a,), Tuple{Vector{Int}}}((values,))
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
spread_open!(values::Vector{Int}, more::Tuple{Vararg{Int}}) = push!(values, more...)
nested_spread!(values::Vector{Int}, more::Tuple{Tuple{Int}}) = push!(values, more[1]...)
dynamic!(container::Any) = push!(container, 1)
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
open_result(f::Any, values::Vector{Int}) = f(values)
open_result_write!(f::Any, values::Vector{Int}) = ((open_result(f, values)::Vector{Int})[1] = 0; nothing)
open_element!(f::Any, values::Vector{Int}) = (f(values[1]); nothing)

@testset "builtin transfer" begin
    none, code, blind = Doubt.none, Doubt.code, Doubt.blind
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
    @test doubts(summary_of(modify_global!).writes) == Dict((global_place(here, :count), false) => none)
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
    none, code = Doubt.none, Doubt.code
    for writer in (pointer_set!, pointer_swap!, pointer_modify!, pointer_replace!)
        @test summary_of(writer, Ptr{Int}).writes[top(2)].doubt == none
    end
    @test doubts(summary_of(pointer_get, Ptr{Int}).reads) == Dict(top(2) => none)
    @test summary_of(llvm, Ptr{Int}).result == Nodes(Node.Placed(parameter(2)) => code, Node.Outside() => code)
    @test summary_of(llvm, Ptr{Int}).writes[(parameter(2), true)].doubt == code
    @test summary_of(global_pointer).result == Nodes(Node.Outside() => code)
    @test summary_of(library_pointer).result == Nodes(Node.Outside() => code)
    # Foreign calls stay open until foreign call table: pointer into string is unknown object.
    @test Set(keys(doubts(summary_of(length_of, String).writes))) == Set([(Place.At(Root.Elsewhere(), Step.Type[]), false), (Place.At(Root.Elsewhere(), Step.Type[]), true)])
end

@testset "statements and calls" begin
    none, code, blind = Doubt.none, Doubt.code, Doubt.blind
    @test summary_of(quoted, Vector{Int}).spread == Dict(Node.Fresh(1) => Nodes(Node.Placed(parameter(2)) => none))
    @test any(nodes -> haskey(nodes, Node.Placed(parameter(2))), values(summary_of(opaque, Vector{Int}).spread))
    @test Node.Placed(parameter(2)) in keys(only(values(summary_of(splat, Vector{Int}).edges)))
    caught_summary = summary_of(caught, Vector{Int})
    @test any(nodes -> haskey(nodes, Node.Outside()), values(caught_summary.edges))
    for (pusher, types) in ((latest!, (Vector{Int},)), (world!, (Vector{Int},)), (invoked!, (Vector{Int},)), (spread!, (Vector{Int}, Tuple{Int, Int})), (nested_spread!, (Vector{Int}, Tuple{Tuple{Int}})))
        @test summary_of(pusher, types...).writes[top(2)].doubt == none
    end
    @test isempty(summary_of(invoke_dead, String).writes)
    @test summary_of(invoke_open, Vector{Int}, Type).writes[(parameter(2), true)].doubt == code
    @test summary_of(invoke_missing, Vector{Int}).writes[(parameter(2), true)].doubt == code
    @test summary_of(spread_open!, Vector{Int}, Tuple{Vararg{Int}}).writes[(parameter(2), true)].doubt == code
    @test summary_of(dynamic!, Any).writes[(parameter(2), true)].doubt == code
    @test summary_of(nested_apply, Vector{Int}, Tuple{Tuple{Int}}).writes[(parameter(2), true)].doubt == code
    @test summary_of(embedded).result == Nodes(Node.Outside() => code)
    @test summary_of(unknown_field, Module, Symbol).result == Nodes(Node.Outside() => code)
    @test summary_of(unknown_any, Module, Symbol, Symbol).result == Nodes(Node.Outside() => code)
    @test haskey(summary_of(first_of_fresh, Vector{Int}).result, Node.Placed(parameter(2)))
    @test haskey(summary_of(any_of_fresh, Vector{Int}, Symbol).result, Node.Placed(parameter(2)))
    @test summary_of(field_global).result == Nodes(Node.Placed(global_place(@__MODULE__, :slot)) => none)
    @test summary_of(make_backed, Vector{Int}).result == Nodes(Node.Placed(parameter(2)) => none)
    run = start_run(nothing)
    instance = something(dispatch(Any[typeof(broken), Int], run.world))
    @test library_body(run, instance) == "inference gave no code"
    @test summary_of(calls_broken, Vector{Int}).writes == Dict()
    broken_int = summary_of(x -> broken(x), Int)
    @test isempty(broken_int.writes)
    # Phi joins both branches; fresh objects escape through globals and caller objects.
    @test doubts(summary_of(pick!, Vector{Int}, Vector{Int}, Bool).writes) == Dict(top(2) => none, top(3) => none)
    @test summary_of(held_write!, Vector{Int}).writes[top(2)].doubt == none
    @test summary_of(nest_write!, Base.RefValue{Base.RefValue{Vector{Int}}}, Vector{Int}).writes[top(3)].doubt == none
    # Callee access below fresh wrapper reaches caller object inside; open result stays possible.
    @test summary_of(open_wrapped!, Any, Vector{Int}).writes[(parameter(3), true)].doubt == code
    @test summary_of(open_result_write!, Any, Vector{Int}).writes[top(3)].doubt == code
    @test all(((place, _),) -> root_of(place) != Root.Parameter(3), keys(summary_of(open_element!, Any, Vector{Int}).writes))
    mktempdir(@__DIR__) do directory
        journal = open_journal(directory)
        try
            target = something(dispatch(Any[typeof(push!), Vector{Int}, Int], run.world))
            push!(journal.crashed, journal_key(target))
            crashed = start_run(journal)
            root = (something(dispatch(Any[typeof(latest!), Vector{Int}], crashed.world)), Pair{Int, Any}[])
            solve!(crashed, [root])
            effect = crashed.summaries[root].writes[(parameter(2), true)]
            @test effect.doubt == blind && effect.reason == "inference crashed process"
            fresh = start_run(journal)
            other = (something(dispatch(Any[typeof(fill_one!), Vector{Int}], fresh.world)), Pair{Int, Any}[])
            solve!(fresh, [other])
            @test any(record -> startswith(record.key, "effects\n") && record.finished, records(directory))
        finally
            close(journal.io)
        end
    end
end

@testset "model and helpers" begin
    @test most(Doubt.none, Doubt.code, Doubt.blind) == Doubt.blind
    @test stronger(Effect(Doubt.code, 3, ""), Effect(Doubt.code, 2, "")) == Effect(Doubt.code, 2, "")
    @test stronger(Effect(Doubt.none, 3, ""), Effect(Doubt.code, 2, "")) == Effect(Doubt.none, 3, "")
    @test same(empty_summary(), empty_summary()) && !same(empty_summary(), open_summary(1, "cause"))
    opened = open_summary(2, "cause")
    @test opened.writes[(parameter(2), true)] == Effect(Doubt.blind, 0, "cause") && opened.result[Node.Outside()] == Doubt.blind
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
    targets = Targets(Origin.Unknown() => Doubt.code)
    @test !add!(targets, Origin.Unknown(), Doubt.blind) && add!(targets, Origin.Unknown(), Doubt.none)
    table = Dict{Tuple{Origin.Type, Bool}, Effect}()
    access!(table, Targets(Origin.Allocation(1) => Doubt.blind), false, Effect(Doubt.blind, 4, "cause"))
    @test table[(Origin.Allocation(1), false)] == Effect(Doubt.blind, 4, "cause")
    run = start_run(nothing)
    instance = something(dispatch(Any[typeof(fill_one!), Vector{Int}], run.world))
    solve!(run, [(instance, Pair{Int, Any}[])])
    code = run.codes[(instance, Pair{Int, Any}[])]
    @test constant(code.ir, GlobalRef(Base, :nothing)) == Some(nothing)
    @test operand_type(code.ir, Operand.Part(Core.Argument(2), 1)) == MemoryRef{Int}
    flow = start_flow(code.ir, code.outcomes, run.referent)
    @test_throws ArgumentError statement!(flow, 1, Expr(:unknown_head), _ -> empty_summary())
    @test_throws ArgumentError statement!(flow, 1, QuoteNode(:literal), _ -> empty_summary())
    @test map_node(flow, Node.Fresh(4), Targets[], 7, 2) == Targets(Origin.Allocation(7) => Doubt.blind)
    @test deep(flow, Targets(Origin.Caller(parameter(2)) => Doubt.none)) == Targets(Origin.Caller(Place.Deep(Root.Parameter(2))) => Doubt.blind)
    @test isa_variant(resolve(code.ir, Operand.Type[Operand.Part(Core.Argument(2), 1)], run.world), Outcome.Open)
    typed = only(unit for unit in UNITS.typed if unit.site.method.name == :add)
    @test cause_span(typed, code, 0) == typed.site.span
    possible_first = Access(parameter(2), false, Confidence.possible, typed.site.span)
    @test worst([possible_first, Access(parameter(2), false, Confidence.definite, typed.site.span)])[1].confidence == Confidence.definite
end

"""Whether `first` and `second` hold same state: same type, and same fields and elements, deep."""
function same_state(first::Any, second::Any)::Bool
    typeof(first) == typeof(second) || return false
    first isa AbstractArray && return size(first) == size(second) && all(map(same_state, first, second))
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
]

@testset "soundness" begin
    for (method, arguments) in CALLS
        @check max_examples = 20 db = false function observed_writes_covered(drawn = arguments)
            before, globals = deepcopy(drawn), globals_now()
            method(drawn...)
            found = effects(nameof(method), map(typeof, drawn)...)
            changed = [Root.Parameter(position + 1) for position in eachindex(drawn) if !same_state(before[position], drawn[position])]
            moved = [Root.Global(GlobalRef(CASES, name)) for (name, old) in globals if !same_state(old, getglobal(CASES, name))]
            all(root -> covered(found, root), [changed; moved])
        end
    end
end
