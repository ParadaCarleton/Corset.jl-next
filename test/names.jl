using Test: @test, @testset, @test_throws
using Corset: Corset
using Corset.Facts: Facts, MethodEffects, Access, Callee, Place, Root, Step, Confidence, EffectKind, BlindSpot, callee_name, place_text, root_global
using Corset.Inference: infer_package
using Corset.Effects: Effects, record_bytes, unit_record, place_root, ALWAYS_THROWS
using Supposition: Supposition, Data, @check
using Random: Xoshiro

const CASE = joinpath(@__DIR__, "names", "NameCases")

"""Fixture module, package facts, inference units, effects facts, blind spots and unit records of `NameCases`."""
function case_facts()::Tuple{Module, Facts.PackageFacts, Corset.Inference.Units, Facts.EffectsFacts, Vector{BlindSpot}, Vector{Union{Nothing, Effects.UnitEffects}}}
    sources = Corset.Discovery.discover(CASE; environment = nothing)
    push!(LOAD_PATH, CASE)
    loaded = try
        Corset.Package.load(sources.project, sources.files)
    finally
        pop!(LOAD_PATH)
    end
    _, _, units, _ = infer_package(loaded.facts, sources.files, nothing, nothing)
    facts, spots, records = Effects.effects_facts(loaded.facts, units)
    return first(loaded.facts.modules), loaded.facts, units, facts, spots, records
end

const CASES, PACKAGE, UNITS, FACTS, SPOTS, RECORDS = case_facts()

"""Effects of fixture method `name`; fixture names are unique."""
effects(name::Symbol)::MethodEffects = only(found for found in FACTS.methods if found.site.method.name == name)

"""Place at parameter `position` (1 is called function) and `steps`."""
parameter(position::Int, steps::Step.Type...)::Place.Type = Place.At(Root.Parameter(position), Step.Type[steps...])

"""Place of fixture global `name`."""
global_place(name::Symbol)::Place.Type = Place.At(Root.Global(GlobalRef(CASES, name)), Step.Type[])

"""Place of global state no binding names."""
const ELSEWHERE = Place.At(Root.Elsewhere(), Step.Type[])

"""Place, coverage, kind and confidence of each of `accesses`."""
shape(accesses::Vector{Access})::Vector{Tuple{Place.Type, Bool, EffectKind.T, Confidence.T}} = [(access.place, access.below, access.kind, access.confidence) for access in accesses]

const DEFINITE, POSSIBLE, MEMORY = Confidence.definite, Confidence.possible, EffectKind.memory

"""Whether inference can prove `effect_free` of fixture: coverage of fixture file counts its counters as effects."""
const PROVES = Base.JLOptions().code_coverage == 0 || Base.JLOptions().code_coverage == 3 && !startswith(CASE, unsafe_string(Base.JLOptions().tracked_path))

@testset "write sources" begin
    # Field assignment calls `setproperty!` before inlining: `!` name writes object or below.
    @test shape(effects(:set_value!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    @test shape(effects(:set_inner!).writes) == [(parameter(2, Step.Field(:box)), true, MEMORY, DEFINITE)]
    @test Set(shape(effects(:set_either!).writes)) == Set([(parameter(2), true, MEMORY, POSSIBLE), (parameter(3), true, MEMORY, POSSIBLE)])
    @test shape(effects(:store_field!).writes) == [(parameter(2), false, MEMORY, DEFINITE)]
    @test shape(effects(:push_value!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    @test shape(effects(:map_into!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    @test Set(shape(effects(:shuffle_with!).writes)) == Set([(parameter(2), true, EffectKind.rng_argument, DEFINITE), (parameter(3), true, MEMORY, DEFINITE)])
    @test shape(effects(:reseed!).writes) == [(ELSEWHERE, true, MEMORY, DEFINITE)]
    @test shape(effects(:solve_upper!).writes) == [(parameter(3), true, MEMORY, DEFINITE)]
    @test shape(effects(:call_setter!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    # Convention breaker writes; its caller trusts its name.
    @test !isempty(effects(:sneaky).writes) && isempty(effects(:call_sneaky).writes)
    @test shape(effects(:zero_bytes!).writes) == [(parameter(2), true, MEMORY, POSSIBLE)]
    @test shape(effects(:collect_into!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    # Closure that only escapes writes nothing in method that builds it.
    @test isempty(effects(:make_callback).writes) && isempty(effects(:wrap_callback).writes) && isempty(effects(:hash_callback).writes)
    @test shape(effects(:register!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    # Store into caller place: later load from it can be stored object.
    @test (parameter(3), true, MEMORY, POSSIBLE) in shape(effects(:store_then_fill!).writes)
    @test shape(effects(:call_callback!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    @test shape(effects(:assumed_foreach!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    @test shape(effects(:claimed_caller!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    @test shape(effects(:keyword_caller!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    # Compiler trusts claim of direct callee, so caller gets no proof.
    @test !effects(:claimed_caller!).effect_free && !effects(:keyword_caller!).effect_free
    @test shape(effects(:forward_keyword!).writes) == [(parameter(2), true, MEMORY, POSSIBLE)]
    @test shape(effects(:poke!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    # Element type comes from declared supertype; package `eltype` method throws.
    @test any(access -> place_root(access.place) == Root.Parameter(2), effects(:set_first!).writes)
    # Tree walk reaches many exact paths; `Deep` of root covers them.
    @test Set(shape(effects(:zero_at!).writes)) == Set([(parameter(2), true, MEMORY, POSSIBLE), (Place.Deep(Root.Parameter(2)), true, MEMORY, POSSIBLE)])
    # Step types come from tuple field and, for `Ref` element, `Any`.
    @test shape(effects(:zero_left!).writes) == [(parameter(2, Step.Position(1)), true, MEMORY, DEFINITE)]
    @test shape(effects(:zero_ref!).writes) == [(parameter(2, Step.Element()), true, MEMORY, DEFINITE)]
    @test shape(effects(:zero_at_index!).writes) == [(Place.Deep(Root.Parameter(2)), true, MEMORY, DEFINITE)]
    @test shape(effects(:push_literal!).writes) == [(ELSEWHERE, true, MEMORY, DEFINITE)]
    # Load from fresh vector can give fresh object, so write is possible.
    @test shape(effects(:fill_wrapped!).writes) == [(parameter(2), true, MEMORY, POSSIBLE)]
    @test (Place.Deep(Root.Parameter(2)), true, MEMORY, POSSIBLE) in shape(effects(:push_all!).writes)
    @test shape(effects(:collect_local!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    @test shape(effects(:swap_local!).writes) == [(parameter(2), true, MEMORY, POSSIBLE)]
    @test shape(effects(:loop_local!).writes) == [(parameter(2), true, MEMORY, POSSIBLE)]
    @test isempty(effects(:thread_count_address).writes)
end

@testset "call results" begin
    # Iteration result holds element of iterated container.
    @test shape(effects(:zero_all!).writes) == [(parameter(2, Step.Element()), true, MEMORY, DEFINITE)]
    @test shape(effects(:zero_first_pair!).writes) == [(parameter(2, Step.Element()), true, MEMORY, DEFINITE)]
    # Other result can hold objects below operand, when its type can hold pointing objects.
    @test shape(effects(:zero_copied!).writes) == [(Place.Deep(Root.Parameter(2)), true, MEMORY, POSSIBLE)]
    @test isempty(effects(:grow_copy).writes) && isempty(effects(:grow_copy).aliases)
    # Element function result: element of container, or other operand.
    @test shape(effects(:zero_lookup!).writes) == [(parameter(2, Step.Element()), true, MEMORY, POSSIBLE)]
    @test (parameter(2, Step.Element()), true, MEMORY, POSSIBLE) in shape(effects(:group!).writes)
    @test shape(effects(:push_lookup!).writes) == [(parameter(2, Step.Element()), true, MEMORY, POSSIBLE)]
    @test Set(shape(effects(:push_handler!).writes)) == Set([(parameter(2, Step.Element()), true, MEMORY, POSSIBLE), (parameter(4), true, MEMORY, POSSIBLE)])
    @test (parameter(3), true, MEMORY, POSSIBLE) in shape(effects(:push_default!).writes)
    # Sample advances default RNG only.
    @test shape(effects(:push_sample!).writes) == [(ELSEWHERE, false, EffectKind.default_rng, DEFINITE)]
    @test any(access -> access.place == Place.Deep(Root.Parameter(2)) && access.confidence == POSSIBLE, effects(:take_bytes).writes)
    @test Set(shape(effects(:zero_larger!).writes)) == Set([(parameter(2), true, MEMORY, POSSIBLE), (parameter(3), true, MEMORY, POSSIBLE)])
    @test shape(effects(:zero_chosen!).writes) == [(parameter(3), true, MEMORY, POSSIBLE)]
    @test Set(shape(effects(:reset_either!).writes)) == Set([(parameter(3), false, MEMORY, POSSIBLE), (parameter(4), false, MEMORY, POSSIBLE)])
    @test shape(effects(:stock!).writes) == [(parameter(2, Step.Element()), true, MEMORY, DEFINITE)]
    @test shape(effects(:zero_listed!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    @test shape(effects(:zero_converted!).writes) == [(parameter(2), true, MEMORY, POSSIBLE)]
    # Package call result that is operand itself waits for package result roots (`effects.md`, Roots).
    @test isempty(effects(:push_same!).writes)
    @test Set(shape(effects(:zero_promoted!).writes)) == Set([(parameter(2), true, MEMORY, POSSIBLE), (parameter(3), true, MEMORY, POSSIBLE)])
    @test shape(effects(:zero_typed_listed!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
end

"""Writing function and confidence of each loop write of fixture method `name`."""
loop_shape(name::Symbol)::Vector{Tuple{String, Confidence.T}} = [(write.callee, write.confidence) for write in effects(name).loop_writes]

@testset "generated method" begin
    # Generated method leaves `Method.source` undefined: claim check reads code compiler infers.
    @test isempty(effects(:generated_double).writes)
    # Claim in generated code voids proof of method and of its direct caller.
    @test !effects(:generated_store!).effect_free && !effects(:optional_store!).effect_free
    @test !effects(:generated_caller!).effect_free
    # Index proof skips generated method that takes array stand-in, dropped branch included: blind spot.
    @test count(spot -> spot.cause == Effects.OFFSET_GENERATED, SPOTS) == 2
end

@testset "loop writes" begin
    # Size change of same object: argument, view of argument, two loads of one field, narrowed argument.
    @test loop_shape(:loop_push!) == [("push!", DEFINITE)]
    @test loop_shape(:loop_keys!) == [("delete!", DEFINITE)]
    @test loop_shape(:loop_field!) == [("push!", DEFINITE)]
    @test loop_shape(:loop_narrowed!) == [("push!", DEFINITE)]
    @test loop_shape(:loop_zipped!) == [("push!", DEFINITE)]
    # Write after inner loop lies outside inner loop body.
    @test isempty(loop_shape(:loop_after_inner!))
    # Base deletes from `Dict` while iterating; array element replacement keeps indices; size change leaves element.
    @test isempty(loop_shape(:loop_dict!)) && isempty(loop_shape(:loop_replace!)) && isempty(loop_shape(:loop_outer!))
    # Package call on holder, field store, or element that loads can make other object.
    @test loop_shape(:loop_holder!) == [("clear!", POSSIBLE)]
    @test loop_shape(:loop_count!) == [("setfield!", POSSIBLE)]
    @test loop_shape(:loop_element!) == [("push!", POSSIBLE)]
    # Field that name selects is `Deep` place: name tier cannot tell objects apart, so write is blind spot.
    @test isempty(loop_shape(:loop_named!)) && any(spot -> spot.cause == Effects.LOOP_UNKNOWN, SPOTS)
    @test isempty(loop_shape(:loop_literal!))
    # Loop without `iterate(x)` starts at its step, after write in source.
    resume = only(effects(:loop_resume!).loop_writes)
    @test resume.callee == "push!" && resume.loop.first_byte > resume.write.first_byte
end

"""Writing function and confidence of each self-alias call of fixture method `name`."""
alias_shape(name::Symbol)::Vector{Tuple{String, Confidence.T}} = [(call.callee, call.confidence) for call in effects(name).self_aliases]

@testset "self aliases" begin
    # Same object to function that breaks on it: library table by module, argument and two loads of one field.
    @test alias_shape(:alias_mul!) == [("mul!", DEFINITE)]
    @test alias_shape(:alias_sum!) == [("sum!", DEFINITE)]
    @test alias_shape(:alias_field!) == [("sum!", DEFINITE)] && alias_shape(:alias_identity!) == [("sum!", DEFINITE)]
    # `splice!` breaks on replacement only; index operand is safe.
    @test alias_shape(:alias_splice!) == [("splice!", DEFINITE)] && isempty(alias_shape(:alias_indices!))
    @test isempty(alias_shape(:alias_index_view!))
    # Overlapping views to warned function: Base docstring, or package docstring with Base warning.
    @test alias_shape(:alias_view!) == [("map!", POSSIBLE)]
    @test alias_shape(:alias_parent!) == [("accumulate!", POSSIBLE)]
    @test alias_shape(:alias_blend!) == [("blend!", POSSIBLE)]
    # Same object to `map!`, unaliasing `copyto!`, unwarned `append!`, other arrays: none.
    # Package submodule named `LinearAlgebra` owns no library function.
    for name in (:alias_map!, :alias_copy!, :alias_append!, :alias_append_view!, :alias_other!, :blend!, :alias_lookalike!)
        @test isempty(alias_shape(name))
    end
end

"""Escape kinds, iterator text and confidence of each stateful reuse of fixture method `name`."""
reuse_shape(name::Symbol)::Vector{Tuple{Bool, Bool, Union{Nothing, String}, Confidence.T}} = [(reuse.earlier_escapes, reuse.later_escapes, reuse.iterator, reuse.confidence) for reuse in effects(name).stateful_reuses]

@testset "stateful reuses" begin
    # Second start of one argument: `first` then loop, `first` inside loop (restarts each pass), zip with itself.
    @test reuse_shape(:reuse_first) == [(false, false, "itr", DEFINITE)]
    @test reuse_shape(:reuse_loop) == [(false, false, "itr", DEFINITE)]
    @test only(effects(:reuse_loop).stateful_reuses).repeats
    @test reuse_shape(:reuse_zip) == [(false, false, "itr", DEFINITE)]
    joint = only(effects(:reuse_zip).stateful_reuses)
    @test !joint.repeats && joint.earlier == joint.later
    # Caller consumes returned zip; load of same element on each pass can give same iterator.
    @test reuse_shape(:reuse_zip_returned) == [(false, false, "itr", DEFINITE)]
    # `isempty` of zip asks `isdone` of each part; part of any type can give `missing`.
    @test reuse_shape(:reuse_zip_empty) == [(false, false, "itr", POSSIBLE)]
    # Nested `zip(z, z)`: each operand starts at most twice per statement, so events grow with chain length only.
    @test reuse_shape(:reuse_zip_chain) == [(false, false, "itr", DEFINITE)]
    chain = only(typed for typed in UNITS.typed if typed.site.method.name == :reuse_zip_chain)
    walk = first(Effects.unit_walk(chain, Set{Module}(PACKAGE.modules), Core.Compiler.NativeInterpreter(), Base.get_world_counter()))
    @test sum(index -> length(Effects.iterator_events(walk, index)), 1:length(walk.ir.stmts)) <= 64
    # Shared part type of nested `zip(z, z)` answers once: 40 levels stay fast.
    nested = foldl((type, _) -> Iterators.Zip{Tuple{type, type}}, 1:40; init = Vector{Int})
    @test Effects.done_missing(walk, nested) == DEFINITE
    # Struct whose field has open parameter type can hold stateful iterator.
    @test reuse_shape(:reuse_relay) == [(false, false, "relays[…]", DEFINITE)]
    # Package `first` of abstract type can iterate field: blind spot, no finding.
    @test any(spot -> spot.cause == Effects.SPECIALIZED_START, SPOTS)
    @test reuse_shape(:reuse_after_dispatched) == [(false, false, "counters[…]", DEFINITE)]
    @test reuse_shape(:reuse_mixed_dispatch) == [(false, false, "sources[…]", POSSIBLE)]
    @test reuse_shape(:reuse_isdone) == [(false, false, "drains[…]", DEFINITE)]
    @test Effects.missing_result(Missing) == DEFINITE && Effects.missing_result(Union{Bool, Missing}) == POSSIBLE
    @test isnothing(Effects.missing_result(Bool)) && isnothing(Effects.missing_result(Union{}))
    # Parameter inside field type: `iterate` body decides kind.
    @test any(spot -> spot.cause == Effects.NESTED_PARAMETER, SPOTS)
    # Field of open parameter is open; parameter inside field type is blind; wrapper of blind family is blind at any depth.
    Pass = Effects.Pass
    kinds = [CASES.Twin => Pass.open, CASES.Relay => Pass.open, CASES.Bag => Pass.blind, CASES.Bag{Int} => Pass.multi, CASES.Relay{<:Number} => Pass.multi]
    append!(kinds, [CASES.Relay{<:CASES.Bag} => Pass.blind, CASES.Relay{<:CASES.Relay{<:CASES.Bag}} => Pass.blind, Union{CASES.Bag, Vector{Int}} => Pass.blind])
    # Bound that is other parameter resolves through it.
    push!(kinds, CASES.Chain => Pass.open)
    for (type, kind) in kinds
        @test Effects.pass_kind(type) == kind
    end
    # Shared bounds of 16 nested levels answer once: about 8 KB, against 88 MB without memo.
    deep = foldl((type, _) -> CASES.Duo{<:type, <:type}, 1:16; init = Vector{Int})
    warm_bytes(type::Type)::Int = (Effects.pass_kind(type); @allocated Effects.pass_kind(type))
    @test Effects.pass_kind(deep) == Pass.multi && warm_bytes(deep) < 1_000_000
    reload = only(effects(:reuse_reload).stateful_reuses)
    @test (reload.repeats, reload.confidence) == (true, POSSIBLE)
    # Element of outer loop starts twice in one pass.
    inner = only(effects(:reuse_inner).stateful_reuses)
    @test (inner.earlier_escapes, inner.later_escapes, inner.repeats, inner.confidence) == (false, false, false, DEFINITE)
    # `isempty` on argument of any type: other `isempty` methods can serve it.
    @test reuse_shape(:reuse_isempty) == [(false, false, "itr", POSSIBLE)]
    # `typeassert` gives its operand: annotated return value and asserted argument are argument itself.
    @test reuse_shape(:reuse_asserted) == [(false, false, "itr", DEFINITE)]
    # Escape after start; start after escape to package function.
    @test reuse_shape(:reuse_return) == [(false, true, "itr", DEFINITE)]
    @test reuse_shape(:reuse_handed) == [(true, false, "itr", DEFINITE)]
    # Stored tuple holds iterator: start after escape of its holder.
    @test reuse_shape(:reuse_stored) == [(true, false, "itr", DEFINITE)]
    # Fresh iterator in returned tuple; union of stateful and multi-pass iterator. Neither has caller name.
    @test reuse_shape(:reuse_fresh) == [(false, true, nothing, DEFINITE)]
    @test reuse_shape(:reuse_mixed) == [(false, false, nothing, DEFINITE)]
    # Multi-pass type, unconsumed `zip`, tuple of fresh value, container built from iterator, threaded state, `popfirst!` write, separate branches, concrete package iterator, stateful kind
    # (`isdone` on `eachline` result, deliberate header skip), new object on each loop pass, `iterate` result, struct family, package `first`, declared field: none.
    kept = (:kept_vector, :kept_zip, :kept_zip_type, :kept_shared, :kept_collected, :kept_state, :kept_popped, :kept_branches, :kept_countdown, :kept_lines, :kept_peeled, :kept_destructured, :kept_nested)
    for name in (kept..., :kept_protocol, :kept_family, :kept_dispatched, :kept_declared, :kept_pair, :kept_enumerated, :kept_marked)
        @test isempty(reuse_shape(name))
    end
end

@testset "exception table" begin
    @test shape(effects(:print_value).writes) == [(parameter(2), true, EffectKind.io, DEFINITE)]
    @test shape(effects(:shout).writes) == [(Place.At(Root.Global(GlobalRef(Base, :stdout)), Step.Type[]), true, EffectKind.io, DEFINITE)]
    @test shape(effects(:draw).writes) == [(parameter(2), false, EffectKind.rng_argument, DEFINITE)]
    @test shape(effects(:draw_default).writes) == [(ELSEWHERE, false, EffectKind.default_rng, DEFINITE)]
    @test (ELSEWHERE, false, EffectKind.default_rng, DEFINITE) in shape(effects(:draw_default).reads)
    @test shape(effects(:hold).writes) == [(parameter(2), false, EffectKind.synchronization, DEFINITE)]
    @test shape(effects(:take_next).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    @test (parameter(2), false, EffectKind.iteration, DEFINITE) in shape(effects(:take_next).reads)
    # Vector part of `zip` restarts unchanged: no write.
    for name in (:drain, :take_one, :zip_drain, :flatten_drain, :first_of_channel, :zip_empty, :zip_empty_items, :zip_collect_items)
        @test shape(effects(name).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    end
    @test shape(effects(:zip_maybe_empty).writes) == [(parameter(2), true, MEMORY, POSSIBLE), (parameter(3), true, MEMORY, POSSIBLE)]
end

@testset "aliases and globals" begin
    @test effects(:first_view).aliases == [parameter(2)] && isempty(effects(:first_view).writes)
    @test shape(effects(:zero_view!).writes) == [(parameter(2), true, MEMORY, DEFINITE)]
    @test effects(:wrap).aliases == [parameter(2)] && isempty(effects(:wrap).writes)
    @test isempty(effects(:set_value!).aliases)
    @test shape(effects(:bump!).writes) == [(global_place(:COUNTER), true, MEMORY, DEFINITE)]
    @test (global_place(:COUNTER), false, MEMORY, DEFINITE) in shape(effects(:bump!).reads)
    @test shape(effects(:set_total!).writes) == [(global_place(:total), false, MEMORY, DEFINITE)]
    @test shape(effects(:read_total).reads) == [(global_place(:total), false, MEMORY, DEFINITE)]
end

@testset "read kinds" begin
    @test shape(effects(:level).reads) == [(global_place(:LEVEL), false, EffectKind.scoped_read, DEFINITE)]
    @test shape(effects(:task_state).reads) == [(ELSEWHERE, false, EffectKind.task_local, DEFINITE)]
    @test shape(effects(:task_value).reads) == [(ELSEWHERE, false, EffectKind.task_local, DEFINITE)]
    @test (parameter(2), false, EffectKind.iteration, DEFINITE) in shape(effects(:finished).reads)
    @test shape(effects(:first_of).reads) == [(parameter(2), false, EffectKind.iteration, DEFINITE)]
    @test shape(effects(:total_of).reads) == [(parameter(2), false, EffectKind.iteration, DEFINITE)]
    @test shape(effects(:emptiness).reads) == [(parameter(2), false, EffectKind.iteration, POSSIBLE)]
    # Plain argument loads stay out of facts.
    @test isempty(effects(:set_value!).reads)
end

@testset "compiler effects and call facts" begin
    @test effects(:add).effect_free == PROVES && isempty(effects(:add).writes) && isempty(effects(:add).reads)
    @test !effects(:push_value!).effect_free && effects(:add).complete
    call = only(fact for fact in effects(:discard).calls if callee_name(fact.callee) == "length")
    @test !call.used && !call.throws && call.terminates && isempty(call.kinds) && !call.stand_in
    push = only(fact for fact in effects(:push_value!).calls if callee_name(fact.callee) == "push!")
    @test push.used && push.kinds == [MEMORY] && push.definite == [MEMORY]
    # Closure operand lends its writes to call that can call it.
    each = only(fact for fact in effects(:collect_into!).calls if callee_name(fact.callee) == "foreach")
    @test each.kinds == [MEMORY] && each.definite == [MEMORY]
    # Block claim makes compiler trust it, so it proves nothing.
    @test !effects(:assumed_store!).effect_free
    @test any(fact -> fact.callee == Callee.Foreign(), effects(:zero_bytes!).calls)
    # Only `eltype` of `BoxRow` always throws.
    @test count(spot -> spot.cause == ALWAYS_THROWS, SPOTS) == 1
end

@testset "walk widens past round limit" begin
    world = Base.get_world_counter()
    typed = first(unit for unit in UNITS.typed if unit.site.method.name == :store_then_fill!)
    walk = first(Effects.unit_walk(typed, Set{Module}(PACKAGE.modules), Effects.CC.NativeInterpreter(world), world))
    Effects.walk_values!(walk, 1)
    # Widened value holds every root as root and `Deep`; next round settles.
    @test all(value -> value.fresh && Place.Deep(Root.Parameter(2)) in value.places && Place.Deep(Root.Parameter(3)) in value.inner, walk.values)
    @test all(stored -> Place.Deep(Root.Parameter(3)) in stored, values(walk.stored))
end

@testset "place helpers" begin
    # Moshi variants are immutable, so table hits compare by `===`; call `==` directly.
    @test Step.Position(1) == Step.Position(1) && Step.Position(1) != Step.Position(2)
    @test Place.Deep(Root.Parameter(2)) == Place.Deep(Root.Parameter(2)) && Place.Deep(Root.Parameter(2)) != Place.Deep(Root.Parameter(3))
    @test hash(Effects.NO_VALUE) == hash(Effects.Value(Set{Place.Type}(), Set{Place.Type}(), false, false))
    @test_throws ArgumentError Facts.NO_STEPS.steps
    counter = GlobalRef(CASES, :COUNTER)
    @test root_global(Place.Deep(Root.Global(counter))) == counter && isnothing(root_global(parameter(2)))
    method = only(methods(CASES.set_inner!))
    @test place_text(method, parameter(2, Step.Field(:box), Step.Element(), Step.Position(1))) == "holder.box[…][1]"
    @test place_text(method, Place.Deep(Root.Global(counter))) == "NameCases.COUNTER or below"
    @test place_text(method, ELSEWHERE) == "global state"
    @test place_text(only(methods(CASES.make_callback(Int[]))), Place.At(Root.Parameter(1), Step.Type[])) == "closure"
end

@testset "unit record round trip" begin
    world = Base.get_world_counter()
    @test length(RECORDS) == length(UNITS.typed)
    for record in RECORDS
        isnothing(record) && continue
        loaded = something(unit_record(record_bytes(record), world))
        @test record_bytes(loaded) == record_bytes(record)
        @test [fact.callee for (_, fact) in loaded.calls] == [fact.callee for (_, fact) in record.calls]
    end
    @test isnothing(unit_record(record_bytes(nothing), world))
end

"""State of fixture argument `argument` that writes change."""
function state(argument::Any)::Any
    argument isa CASES.Box && return argument.value
    argument isa CASES.Holder && return argument.box.value
    argument isa Vector{CASES.Box} && return [box.value for box in argument]
    return argument isa Dict{Symbol, CASES.Box} ? Dict(key => box.value for (key, box) in argument) : argument
end

"""Whether facts of `name` hold write on parameter `position` or below it."""
writes_parameter(name::Symbol, position::Int)::Bool = any(access -> place_root(access.place) == Root.Parameter(position), effects(name).writes)

@testset "soundness on fixtures that follow convention" begin
    vectors, numbers = Data.Vectors(Data.Integers(-9, 9); min_size = 2, max_size = 6), Data.Integers(-9, 9)
    @check max_examples = 40 db = false function observed_writes_have_facts(items = vectors, number = numbers, pick = Data.Booleans())
        cases = (
            :set_value! => (CASES.Box(0), number), :set_inner! => (CASES.Holder(CASES.Box(0)), number),
            :set_either! => (CASES.Box(1), CASES.Box(1), pick), :push_value! => (copy(items), number),
            :map_into! => (copy(items), copy(items)), :shuffle_with! => (Xoshiro(number), copy(items)),
            :call_setter! => (CASES.Box(number),), :zero_view! => (copy(items),), :collect_into! => (Int[], copy(items)),
            :first_of => (copy(items),), :total_of => (copy(items),), :wrap => (CASES.Box(number),),
            :call_callback! => (copy(items),), :forward_keyword! => (copy(items),), :assumed_store! => (copy(items),),
            :store_then_fill! => ([copy(items)], copy(items)), :register! => (Function[], copy(items)),
            :assumed_foreach! => (Int[], copy(items)), :claimed_caller! => (copy(items),), :keyword_caller! => (copy(items),),
            :fill_wrapped! => (copy(items),), :push_all! => (copy(items), copy(items)), :collect_local! => (Int[], copy(items)),
            :zero_all! => (CASES.Box.(items),), :zero_copied! => (CASES.Box.(items),), :grow_copy => (copy(items),),
            :zero_lookup! => (Dict(:a => CASES.Box(number)),), :group! => (Dict(:a => copy(items)), :a, number),
        )
        return all(cases) do (name, arguments)
            before = map(state ∘ deepcopy, arguments)
            getfield(CASES, name)(arguments...)
            changed = [index for index in eachindex(arguments) if !isequal(before[index], state(arguments[index]))]
            all(index -> writes_parameter(name, index + 1), changed)
        end
    end
end
