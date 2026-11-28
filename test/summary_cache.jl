# Summary cache: library summaries and method store records give facts of cold run (`engine.md`, Solve and cache).

using Test: @test, @testset, @test_throws
using Corset: Corset
using Corset.Cache: Cache
using Corset.Facts: Facts, MethodEffects, Callee, BlindSpot, callee_methods
using Corset.Inference: Inference, infer_package, Store, entry_key, serialized, edge_instance
using Corset.Effects.Summaries:
    Summaries, MethodVerdict, UnitVerdict, Library, LibraryEntry, Summary, Run, Variant, Closure, start_run, solve!, dispatch, root_summary!, same, cached_effects,
    library_entries!, unshared!, closure_key!, variant_key!, instance_key!, instance_node, record_text!, stored_value!, type_text!, inferred!,
    record_bytes, unit_record, structure_text!, held_summary
using EvilArrays: EvilArray
using Moshi.Data: isa_variant
using Serialization: deserialize
using Random: RandomDevice

const CASE = joinpath(@__DIR__, "effects", "EffectsCases")

"""Fixture module, files and package facts of `EffectsCases`, loaded with case on load path."""
function case_package()::Tuple{Module, Vector{Facts.SyntaxFile}, Facts.PackageFacts}
    sources = Corset.Discovery.discover(CASE; environment = nothing)
    push!(LOAD_PATH, CASE)
    loaded = try
        Corset.Package.load(sources)
    finally
        pop!(LOAD_PATH)
    end
    return first(loaded.facts.modules), loaded.sources.files, loaded.facts
end

const CASES, FILES, PACKAGE = case_package()

"""Units and used method store of inference run that `store` serves."""
function inferred(store::Store)::Tuple{Inference.Units, Store}
    _, _, units, used = infer_package(PACKAGE, FILES, store, nothing)
    return units, something(used)
end

"""Stored verdicts of inference run that infers every unit: none."""
const NONE_STORED = Union{Nothing, UnitVerdict}[]

const UNITS, USED = inferred(Store())
const FACTS, SPOTS, RECORDS, LIBRARY = cached_effects(PACKAGE, UNITS, NONE_STORED, nothing, Library())

"""`effects` stage run of every unit without library cache: name tier records with engine verdicts."""
const RUN = Corset.Effects.effects_facts(PACKAGE, UNITS, nothing, Library())

"""Text of verdict of each method, method in place of site: runs that agree give same text."""
fact_text(facts::AbstractVector{MethodVerdict})::Vector{String} = [repr(Any[found.site.method; [getfield(found, name) for name in fieldnames(MethodVerdict)[2:end]]]) for found in facts]

"""Text of `effects` stage facts of each method, method in place of site: runs that agree give same text."""
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

"""New package UUID: test sets reseed default random generator, so it would repeat UUID of earlier test set."""
fresh_uuid()::Base.UUID = Base.UUID(rand(RandomDevice(), UInt128))

"""Closure key state without rejected instances."""
fresh()::Closure = Closure(Base.IdSet{Core.MethodInstance}())

"""Calls whose native edges show each record form of Julia 1.13 (`record_text!`)."""
module Forms
    single_target(x::Int) = x + 1
    single(x::Int) = single_target(x)
    several_target(x::Int) = 1
    several_target(x::Int8) = 2
    several_target(x::Int16) = 3
    several(x::Signed) = several_target(x)
    covering_target(x::Int) = 1
    covering_target(x::Signed) = 2
    covering(x::Signed) = covering_target(x)
    many_target(x::Int) = 1
    many_target(x::Int8) = 2
    many_target(x::Int16) = 3
    many_target(x::Int32) = 4
    many(x::Signed) = many_target(x)
    invoked_target(x::Any) = x
    invoked(x::Int) = invoke(invoked_target, Tuple{Any}, x)
    global counter::Int = 0
    bound() = getglobal(Forms, :counter)
    # Serializer calls package `write` of enum value, which throws here.
    @enum Mode plain fancy
    Base.write(::IO, ::Mode) = error("`Mode` has no byte form")
end

"""Native edges of `f` on `types` that `run` infers, and text of each record (`record_text!`)."""
function record_texts(run::Run, f::Any, types::Type...)::Tuple{Vector{Any}, Vector{String}}
    instance = instance_of(f, types...)
    inferred!(run, instance)
    edges, texts, position = collect(Any, run.cache.edges[instance]), String[], 1
    while position <= length(edges)
        text, position = something(record_text!(run, edges, position, Module[], Any[]))
        push!(texts, text)
    end
    return edges, texts
end

"""Write package `name` with `uuid`, `source` and project `sections` under `parent`; load it with `roots` on load path."""
function load_package(parent::String, name::String, uuid::Base.UUID, source::String, sections::String, roots::Vector{String})::Tuple{Module, String}
    root = joinpath(parent, name)
    mkpath(joinpath(root, "src"))
    write(joinpath(root, "Project.toml"), "name = \"$name\"\nuuid = \"$uuid\"\n$sections")
    write(joinpath(root, "src", "$name.jl"), source)
    append!(LOAD_PATH, [roots; root])
    try
        return Base.require(Base.PkgId(uuid, name)), root
    finally
        filter!(path -> path != root && !(path in roots), LOAD_PATH)
    end
end

const LIB_SOURCE = """
module Lib
target(x::Signed) = 1
call(x::Int8) = target(x)
wide(x::Int) = 1
wide(x::Int8) = 2
wide(x::Int16) = 3
call_wide(x::Vector{Signed}) = wide(x[1])
ping(n::Int) = n <= 0 ? 0 : pong(n - 1)
pong(n::Int) = n <= 0 ? 1 : ping(n - 1)
unused(x::Int) = x + 1
mismatch(x::String) = x
missing_call(x::Vector{Int}) = (push!(x, 1); mismatch(x))
end
"""

const PIRATE_SOURCE = """
module Pirate
using Lib: Lib
Lib.target(x::Int8) = 2
Lib.wide(x::Int32) = 4
end
"""

"""Library cache entries of solve of `f` on `types` with empty cache, after round trip through bytes."""
library_of(f::Any, types::Type...)::Library = reread(library_entries!(first(solved(Library(), Module[], f, types...))))

"""Whether solve of `f` on `types` with `library` takes summary of its root from library cache."""
function root_hit(library::Library, f::Any, types::Type...)::Bool
    run, root = solved(library, Module[], f, types...)
    key = variant_key!(run, fresh(), root)
    return !isnothing(key) && something(key) in run.cache.hits
end

@testset "summary cache" begin
    @testset "edge forms" begin
        run = start_run(nothing, Module[], Library())
        edges, texts = record_texts(run, Forms.single, Int)
        @test only(edges) isa Core.CodeInstance && startswith(only(texts), "call instance ")
        # Lookup without covering match marks call type with method table, then lists matches with negative count.
        edges, texts = record_texts(run, Forms.several, Signed)
        @test any(edge -> edge === Core.methodtable, edges) && sort!(first.(split.(texts))) == ["lookup", "table"] && any(startswith("lookup -3 "), texts)
        edges, texts = record_texts(run, Forms.covering, Signed)
        @test any(startswith("lookup 2 "), texts)
        # Too many matches leave no record.
        @test isempty(first(record_texts(run, Forms.many, Signed)))
        edges, texts = record_texts(run, Forms.invoked, Int)
        @test first(edges) isa Type && startswith(only(texts), "instance ")
        edges, texts = record_texts(run, Forms.bound)
        @test only(edges) isa Core.Binding && only(texts) == "binding $(join(fullname(Forms), '.')) counter"
        method = which(Forms.single_target, (Int,))
        @test startswith(first(something(record_text!(run, Any[method], 1, Module[], Any[]))), "call method ")
        # Other form, or call type without target, has no text.
        @test isnothing(record_text!(run, Any[:other], 1, Module[], Any[])) && isnothing(record_text!(run, Any[Int], 1, Module[], Any[]))
    end

    @testset "type texts" begin
        run = start_run(nothing, Module[], Library())
        text(type::Any)::String = first(type_text!(run, type))
        first_variable, second_variable, inner = TypeVar(:T), TypeVar(:S), TypeVar(:T)
        # Renamed variable gives same text; variable counts by binding depth, so inner variable shadows outer one.
        @test text(UnionAll(first_variable, Tuple{first_variable, first_variable})) == text(UnionAll(second_variable, Tuple{second_variable, second_variable}))
        @test text(UnionAll(first_variable, Tuple{first_variable, Int})) != text(UnionAll(first_variable, Tuple{Int, first_variable}))
        @test text(UnionAll(first_variable, UnionAll(inner, Tuple{first_variable, inner}))) != text(UnionAll(first_variable, UnionAll(inner, Tuple{inner, first_variable})))
        # Free variable counts by name and bounds.
        @test text(first_variable) == text(TypeVar(:T)) != text(TypeVar(:T, Integer))
        # Depth counts from innermost variable, also in offset bound stack.
        @test structure_text!(run, first_variable, EvilArray(TypeVar[first_variable, inner]), Module[]) == structure_text!(run, first_variable, TypeVar[first_variable, inner], Module[]) == "bound 1"
        values = Any[Val{1}, Val{Int32(1)}, Val{1.0}, Val{true}, Val{:a}, Val{(:a, 1)}, Val{(:a, 2)}, Val{Forms.plain}, Val{Forms.fancy}, Union{}, Nothing, Union{Int, String}, Union{Int, Symbol}, Tuple{Vararg{Int}}, NTuple{2, Int}, Val{Base.Iterators}, Val{Base}]
        @test allunique(map(text, values))
        # Text holds content alone: other run agrees.
        @test map(text, values) == [first(type_text!(start_run(nothing, Module[], Library()), type)) for type in values]
        # Type names root modules: module parameter, name and parameters.
        @test Set(last(type_text!(run, Tuple{typeof(Forms.single), Val{Base.Iterators}, Core.SimpleVector}))) == Set([Main, Base, Core])
    end

    @testset "closure keys" begin
        mktempdir(@__DIR__; prefix = ".jl_") do scratch
            lib, _ = load_package(scratch, "Lib", fresh_uuid(), LIB_SOURCE, "", String[])
            precompile(lib.ping, (Int,))
            run = start_run(nothing, Module[], Library())
            ping, pong = instance_of(lib.ping, Int), instance_of(lib.pong, Int)
            # Mutual recursion gives one component: either walk order gives same keys.
            @test any(edge -> edge_instance(edge) === pong, instance_node(run, ping).edges) && any(edge -> edge_instance(edge) === ping, instance_node(run, pong).edges)
            forward, backward = fresh(), fresh()
            keys_forward = [closure_key!(run, forward, ping), closure_key!(run, forward, pong)]
            keys_backward = reverse([closure_key!(run, backward, pong), closure_key!(run, backward, ping)])
            @test keys_forward == keys_backward && allunique(keys_forward) && !any(isnothing, keys_forward)
            @test closure_key!(start_run(nothing, Module[], Library()), fresh(), ping) == first(keys_forward)
            # Rejected member, package code, or `Main` code has no key.
            @test isnothing(closure_key!(run, Closure(Base.IdSet{Core.MethodInstance}([pong])), ping))
            @test isnothing(closure_key!(start_run(nothing, [lib], Library()), fresh(), ping))
            # Caller of callee without key has no key either.
            precompile(lib.call, (Int8,))
            called = instance_of(lib.call, Int8)
            @test !isnothing(closure_key!(run, fresh(), called)) && isnothing(closure_key!(run, Closure(Base.IdSet{Core.MethodInstance}([instance_of(lib.target, Int8)])), called))
            precompile(relay_add, (Int,))
            @test isnothing(closure_key!(run, fresh(), instance_of(relay_add, Int)))
            # Instance without node has no key until run infers it; then run edges give key.
            unused = instance_of(lib.unused, Int)
            @test isnothing(instance_node(run, unused)) && isnothing(closure_key!(run, fresh(), unused))
            @test inferred!(run, unused) isa Tuple && instance_node(run, unused) === unused && !isnothing(closure_key!(run, fresh(), unused))
            # Body that calls outside native edges cannot share: call without method dispatches nowhere.
            missing_run, missing_root = solved(Library(), Module[], lib.missing_call, Vector{Int})
            called, called_root = solved(Library(), Module[], lib.ping, Int)
            @test missing_root in unshared!(missing_run, fresh()) && !(called_root in unshared!(called, fresh()))
        end
        # Other process with other loaded packages gives same key.
        precompile(push!, (Vector{Int}, Int))
        here = closure_key!(start_run(nothing, Module[], Library()), fresh(), instance_of(push!, Vector{Int}, Int))
        code = "using Corset.Effects.Summaries: Summaries; precompile(push!, (Vector{Int}, Int)); instance = Base.method_instance(push!, Tuple{Vector{Int}, Int}); print(Summaries.closure_key!(Summaries.start_run(nothing, Module[], Summaries.Library()), Summaries.Closure(Base.IdSet{Core.MethodInstance}()), instance))"
        @test !isnothing(here) && readchomp(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`) == here
    end

    @testset "library entries" begin
        cold, root = solved(Library(), Module[], push!, Vector{Int}, Int)
        entries = reread(library_entries!(cold))
        key = something(variant_key!(cold, fresh(), root))
        @test haskey(entries.entries, key) && instance_key!(cold, first(root)) in entries.instances
        # Hit needs no body: walk stops at it, and run finds no new entry.
        warm, _ = solved(entries, Module[], push!, Vector{Int}, Int)
        @test key in warm.cache.hits && isempty(warm.codes) && isempty(warm.bodies) && same(root_summary!(warm, root), root_summary!(cold, root))
        @test isempty(library_entries!(warm))
        # Summary with callback record stays out.
        precompile(CASES.call_setter!, (CASES.Setter, Int))
        setter, setter_root = solved(Library(), Module[], CASES.call_setter!, CASES.Setter, Int)
        setter_key = variant_key!(setter, fresh(), setter_root)
        @test !isempty(held_summary(setter.slots, setter_root).callbacks) && !isnothing(setter_key) && !haskey(library_entries!(setter).entries, something(setter_key))
        # Caller of package method stays out, though its own signature names no package type.
        relay, relay_root = solved(Library(), [CASES], relay_twice, Int)
        @test relay_root in unshared!(relay, fresh())
        # Variant with package module as constant stays out.
        named, _ = solved(Library(), [CASES], CASES.read_module)
        moduled = [variant for variant in keys(named.slots) if any(constant -> last(constant) === CASES, last(variant))]
        @test !isempty(moduled) && issubset(moduled, unshared!(named, fresh()))
        # Entry holds throw helper verdicts its closure read, and hits only while each holds.
        instance = first(root)
        for (verdict, hit) in [(true, true), (false, false)]
            bytes = serialized(LibraryEntry(Set([1]), Pair{Any, Bool}[error => verdict]))
            run = start_run(nothing, Module[], Library(Dict("entry" => Cache.Stamped("instance", bytes, 0.0))))
            @test (stored_value!(run, Set{Int}, "entry", instance) == Set([1])) == hit && ("entry" in run.cache.hits) == hit
        end
    end

    @testset "library hit" begin
        stored = reread(LIBRARY)
        found = [(deserialize(IOBuffer(stamped.bytes))::LibraryEntry).value for stamped in values(stored.entries)]
        @test any(entry -> entry isa Summary, found) && any(entry -> entry isa Set{Int}, found) && any(entry -> entry isa Bool, found)
        @test all(entry -> !(entry isa Summary) || isempty(entry.callbacks), found)
        # Unrelated package loaded after store keeps every hit.
        mktempdir(@__DIR__; prefix = ".jl_") do scratch
            load_package(scratch, "Unrelated", fresh_uuid(), "module Unrelated\nf() = 1\nend\n", "", String[])
            facts, spots, records, new, hits = cached_effects(PACKAGE, UNITS, NONE_STORED, nothing, stored)
            @test fact_text(facts) == fact_text(FACTS) && spots == SPOTS && repr(records) == repr(RECORDS)
            @test isempty(new) && !isempty(hits) && issubset(hits, keys(stored.entries))
        end
        # Run that skipped crashed instance keeps blind spot of this run only, so it stores nothing.
        mktempdir(@__DIR__; prefix = ".jl_") do directory
            journal = Inference.Journal(open(joinpath(directory, "journal"), "a"), Set(["effects\nother"]), Set{String}())
            try
                @test isempty(cached_effects(PACKAGE, UNITS, NONE_STORED, journal, Library())[4])
            finally
                close(journal.io)
            end
        end
    end

    @testset "package edits" begin
        mktempdir(@__DIR__; prefix = ".jl_") do scratch
            lib_uuid = fresh_uuid()
            lib, lib_root = load_package(scratch, "Lib", lib_uuid, LIB_SOURCE, "", String[])
            _, other_root = load_package(scratch, "Other", fresh_uuid(), "module Other\nf() = 1\nend\n", "", String[])
            precompile(lib.ping, (Int,))
            precompile(lib.call, (Int8,))
            precompile(lib.call_wide, (Vector{Signed},))
            pinged, called, widened = library_of(lib.ping, Int), library_of(lib.call, Int8), library_of(lib.call_wide, Vector{Signed})
            @test root_hit(pinged, lib.ping, Int) && root_hit(called, lib.call, Int8) && root_hit(widened, lib.call_wide, Vector{Signed})
            # Edit of unrelated package keeps hit; edit of package that owns reached method misses.
            write(joinpath(other_root, "src", "Other.jl"), "module Other\nf() = 2\nend\n")
            @test root_hit(pinged, lib.ping, Int)
            write(joinpath(lib_root, "src", "Lib.jl"), LIB_SOURCE * "# edited\n")
            @test !root_hit(pinged, lib.ping, Int)
            write(joinpath(lib_root, "src", "Lib.jl"), LIB_SOURCE)
            @test root_hit(pinged, lib.ping, Int)
            # Method of other package changes dispatch of library call, and pushes other call past method limit.
            load_package(scratch, "Pirate", fresh_uuid(), PIRATE_SOURCE, "\n[deps]\nLib = \"$lib_uuid\"\n", [lib_root])
            precompile(lib.call, (Int8,))
            precompile(lib.call_wide, (Vector{Signed},))
            @test !root_hit(called, lib.call, Int8)
            @test !root_hit(widened, lib.call_wide, Vector{Signed})
            @test root_hit(pinged, lib.ping, Int)
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
        filled = Corset.Effects.with_records(USED, UNITS, RUN, FILES, PACKAGE, nothing)
        @test all(entry -> !isempty(entry.effects), values(filled)) && all(entry -> isempty(entry.effects), values(USED))
        units, used = inferred(copy(filled))
        @test isempty(units.typed) && !isempty(units.stored) && keys(used) == keys(filled)
        run = Corset.Effects.effects_facts(PACKAGE, units, nothing, Library())
        @test fact_text(run.facts) == fact_text(RUN.facts) && run.spots == RUN.spots && isempty(run.fresh) && isempty(run.verdicts)
        # Callers infer again while their callees stay stored: callee keeps unit body, so facts agree.
        callers = Set(entry_key(typed.site.method, typed.signature) for typed in UNITS.typed if startswith(string(typed.site.method.name), "call_"))
        units, _ = inferred(filter(((key, _),) -> !(key in callers), filled))
        @test !isempty(units.typed) && !isempty(units.stored)
        run = Corset.Effects.effects_facts(PACKAGE, units, nothing, reread(LIBRARY))
        @test fact_text(run.facts) == fact_text(RUN.facts) && run.spots == RUN.spots
    end

    @testset "engine stage" begin
        none = (nothing, BlindSpot[], nothing, BlindSpot[], nothing)
        @test Corset.Engine.stage_facts(CASE, nothing, FILES, true, true, false, nothing, nothing, nothing) == none
        @test Corset.Engine.stage_facts(CASE, PACKAGE, FILES, false, true, false, nothing, nothing, nothing) == none
        mktempdir(@__DIR__; prefix = ".jl_") do cache
            staged(effects::Bool)::Tuple = Corset.Engine.stage_facts(CASE, PACKAGE, FILES, true, effects, false, cache, nothing, nothing)
            entry = Corset.Engine.method_entry(CASE)
            store() = Cache.lookup(Store, cache, entry, readline(Cache.entry(cache, entry)); root = nothing)
            # Inference run keeps no records; effects run infers their units again.
            @test isnothing(staged(false)[3]) && all(found -> isempty(found.effects), values(store()))
            _, _, facts, spots = staged(true)
            @test fact_text(facts) == fact_text(RUN.facts) && spots == RUN.spots && all(found -> !isempty(found.effects), values(store()))
            @test length(readdir(Cache.library_directory(cache))) == 1
            # Stored entries keep their records through inference run.
            staged(false)
            @test all(found -> !isempty(found.effects), values(store()))
            # Fresh units with library summaries, then stored units only.
            rm(Cache.entry(cache, entry))
            @test fact_text(staged(true)[3]) == fact_text(RUN.facts)
            @test fact_text(staged(true)[3]) == fact_text(RUN.facts)
            @test length(readdir(Cache.library_directory(cache))) == 1
        end
        mktempdir(@__DIR__; prefix = ".jl_") do directory
            mktempdir(@__DIR__; prefix = ".jl_") do cache
                @test fact_text(Corset.Engine.stage_facts(CASE, PACKAGE, FILES, true, true, false, cache, directory, nothing)[3]) == fact_text(RUN.facts)
            end
        end
    end
end
