# Summary cache: library summaries and method store records give facts of cold run (`effects.md`, Solve and cache).

using Test: @test, @testset, @test_throws
using Corset: Corset
using Corset.Cache: Cache
using Corset.Facts: Facts, MethodEffects, Callee, BlindSpot
using Corset.Inference: Inference, infer_package, Store, entry_key, serialized
using Corset.Effects:
    Effects, Library, Run, Variant, start_run, solve!, dispatch, root_summary, same, cached_effects, library_entries, outside!, package_reach,
    instance_key!, inferred!, record_bytes, unit_record, callee_methods
using Moshi.Data: isa_variant
using Serialization: deserialize

const CASE = joinpath(@__DIR__, "effects", "EffectsCases")

"""Fixture module, files and package facts of `EffectsCases`, loaded with case on load path."""
function case_package()::Tuple{Module, Vector{Facts.SyntaxFile}, Facts.PackageFacts}
    sources = Corset.Discovery.discover(CASE; environment = nothing)
    push!(LOAD_PATH, CASE)
    loaded = try
        Corset.Package.load(sources.project, sources.files)
    finally
        pop!(LOAD_PATH)
    end
    return first(loaded.facts.modules), sources.files, loaded.facts
end

const CASES, FILES, PACKAGE = case_package()

"""Units and used method store of inference run that `store` serves."""
function inferred(store::Store)::Tuple{Inference.Units, Store}
    _, _, units, used = infer_package(PACKAGE, FILES, store, nothing)
    return units, something(used)
end

const UNITS, USED = inferred(Store())
const FACTS, SPOTS, RECORDS, LIBRARY = cached_effects(PACKAGE, UNITS, nothing, Library())

"""Text of facts of each method, method in place of site: runs that agree give same text."""
fact_text(facts::Facts.EffectsFacts)::Vector{String} = [repr(Any[found.site.method; [getfield(found, name) for name in fieldnames(MethodEffects)[2:end]]]) for found in facts.methods]

"""`data` after round trip through bytes, as disk cache keeps it."""
reread(data::T) where {T} = deserialize(IOBuffer(serialized(data)))::T

"""Instance of method of `f` on argument `types`."""
instance_of(f::Any, types::Type...)::Core.MethodInstance = only(something(dispatch(Any[typeof(f), types...], Base.get_world_counter(), 1)))

"""Run with library cache `library` for package `modules`, solved from instance of `f` on `types`, and its root."""
function solved(library::Library, modules::Vector{Module}, f::Any, types::Type...)::Tuple{Run, Variant}
    run = start_run(nothing, modules, library)
    root = (instance_of(f, types...), Pair{Int, Any}[])
    solve!(run, [root])
    return run, root
end

relay_add(x::Int)::Int = CASES.add(x, 1)
relay_twice(x::Int)::Int = relay_add(x) + relay_add(x)
never_called(x::Int)::Int = x + 2
inferred_once(x::Int)::Int = x + 3

@testset "summary cache" begin
    @testset "library instances" begin
        precompile(relay_twice, (Int,))
        precompile(push!, (Vector{Int}, Int))
        precompile(push!, (Vector{CASES.Box}, CASES.Box))
        run = start_run(nothing, [CASES], Library())
        # Search that finds no package code marks each instance it visited.
        @test outside!(run, instance_of(push!, Vector{Int}, Int)) && count(values(run.cache.outside)) > 1
        # Package method, signature with package type, and instance without code count as package.
        @test !outside!(run, instance_of(CASES.add, Int, Int)) && !outside!(run, instance_of(push!, Vector{CASES.Box}, CASES.Box))
        @test !outside!(run, instance_of(never_called, Int))
        # Native edges reach package method; caller of known package instance stops there.
        @test !outside!(run, instance_of(relay_add, Int)) && !outside!(run, instance_of(relay_twice, Int))
        # Instance that run inferred lends its inference edges.
        once = instance_of(inferred_once, Int)
        @test inferred!(run, once) isa Tuple && outside!(run, once)
    end

    @testset "library entries" begin
        cold, root = solved(Library(), Module[], push!, Vector{Int}, Int)
        entries = reread(library_entries(cold))
        key = (instance_key!(cold, first(root)), Pair{Int, Any}[])
        @test haskey(entries.summaries, key)
        # Hit needs no body: walk stops at it, and run finds no new entry.
        warm, _ = solved(entries, Module[], push!, Vector{Int}, Int)
        @test warm.summaries[root] === entries.summaries[key] && isempty(warm.codes) && isempty(warm.bodies) && same(root_summary(warm, root), root_summary(cold, root))
        @test isempty(library_entries(warm))
        # Summary with callback record stays out.
        precompile(CASES.call_setter!, (CASES.Setter, Int))
        setter, setter_root = solved(Library(), Module[], CASES.call_setter!, CASES.Setter, Int)
        @test !isempty(setter.summaries[setter_root].callbacks) && outside!(setter, first(setter_root))
        @test !haskey(library_entries(setter).summaries, (instance_key!(setter, first(setter_root)), Pair{Int, Any}[]))
        # Caller of package method stays out, though its own signature names no package type.
        relay, relay_root = solved(Library(), [CASES], relay_twice, Int)
        @test relay_root in package_reach(relay) && !any(variant -> first(variant).def.module === @__MODULE__, keys(relay.summaries) ∩ keys(library_entries(relay).summaries))
        # Variant with package module as constant stays out.
        named, _ = solved(Library(), [CASES], CASES.read_module)
        moduled = [variant for variant in keys(named.summaries) if any(constant -> last(constant) === CASES, last(variant))]
        @test !isempty(moduled) && issubset(moduled, package_reach(named))
    end

    @testset "library hit" begin
        stored = reread(LIBRARY)
        @test !isempty(stored.summaries) && !isempty(stored.fields) && !isempty(stored.cuts)
        @test all(summary -> isempty(summary.callbacks), values(stored.summaries))
        facts, spots, records, found = cached_effects(PACKAGE, UNITS, nothing, stored)
        @test fact_text(facts) == fact_text(FACTS) && spots == SPOTS && repr(records) == repr(RECORDS)
        @test isempty(found)
        # Run that skipped crashed instance keeps blind spot of this run only, so it stores nothing.
        mktempdir(@__DIR__) do directory
            journal = Inference.Journal(open(joinpath(directory, "journal"), "a"), Set(["effects\nother"]))
            try
                @test isempty(last(cached_effects(PACKAGE, UNITS, journal, Library())))
            finally
                close(journal.io)
            end
        end
    end

    @testset "unit records" begin
        world = Base.get_world_counter()
        @test all(record -> repr(unit_record(record_bytes(record), world)) == repr(record), RECORDS)
        calls = [fact for record in RECORDS if !isnothing(record) for (_, fact) in record.calls]
        # Round trip covers callee methods, dead call and builtin.
        callees = [callee_methods(fact.callee) for fact in calls]
        @test any(found -> !isnothing(found) && !isempty(found), callees) && any(found -> !isnothing(found) && isempty(found), callees)
        @test any(fact -> isa_variant(fact.callee, Callee.Builtin), calls)
        @test isnothing(unit_record(record_bytes(nothing), world))
        @test_throws ArgumentError unit_record(UInt8[], world)
    end

    @testset "stored units" begin
        filled = Corset.Engine.with_records(USED, UNITS, RECORDS)
        @test all(entry -> !isempty(entry.effects), values(filled)) && all(entry -> isempty(entry.effects), values(USED))
        units, used = inferred(copy(filled))
        @test isempty(units.typed) && !isempty(units.stored) && keys(used) == keys(filled)
        facts, spots, records, _ = cached_effects(PACKAGE, units, nothing, Library())
        @test fact_text(facts) == fact_text(FACTS) && spots == SPOTS && isempty(records)
        # Callers infer again while their callees stay stored: callee keeps unit body, so facts agree.
        callers = Set(entry_key(typed.site.method, typed.signature) for typed in UNITS.typed if startswith(string(typed.site.method.name), "call_"))
        units, _ = inferred(filter(((key, _),) -> !(key in callers), filled))
        @test !isempty(units.typed) && !isempty(units.stored)
        facts, spots, _, _ = cached_effects(PACKAGE, units, nothing, reread(LIBRARY))
        @test fact_text(facts) == fact_text(FACTS) && spots == SPOTS
    end

    @testset "engine stage" begin
        none = (nothing, BlindSpot[], nothing, BlindSpot[])
        @test Corset.Engine.stage_facts(CASE, nothing, FILES, true, true, nothing, nothing) == none
        @test Corset.Engine.stage_facts(CASE, PACKAGE, FILES, false, true, nothing, nothing) == none
        mktempdir(@__DIR__) do cache
            staged(effects::Bool)::Tuple = Corset.Engine.stage_facts(CASE, PACKAGE, FILES, true, effects, cache, nothing)
            entry = Corset.Engine.method_entry(CASE)
            store() = Cache.lookup(Store, cache, entry, readline(Cache.entry(cache, entry)))
            # Inference run keeps no records; effects run infers their units again.
            @test isnothing(staged(false)[3]) && all(found -> isempty(found.effects), values(store()))
            _, _, facts, spots = staged(true)
            @test fact_text(facts) == fact_text(FACTS) && spots == SPOTS && all(found -> !isempty(found.effects), values(store()))
            @test length(readdir(Cache.library_directory(cache))) == 1
            # Stored entries keep their records through inference run.
            staged(false)
            @test all(found -> !isempty(found.effects), values(store()))
            # Fresh units with library summaries, then stored units only.
            rm(Cache.entry(cache, entry))
            @test fact_text(staged(true)[3]) == fact_text(FACTS)
            @test fact_text(staged(true)[3]) == fact_text(FACTS)
            @test length(readdir(Cache.library_directory(cache))) == 1
        end
        mktempdir(@__DIR__) do directory
            mktempdir(@__DIR__) do cache
                @test fact_text(Corset.Engine.stage_facts(CASE, PACKAGE, FILES, true, true, cache, directory)[3]) == fact_text(FACTS)
            end
        end
    end
end
