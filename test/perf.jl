# Speed: syntax budget on legacy source, and cost linear in function size and in chain of locals.

using Corset: Corset
using Corset.Facts: FactSet, Role
using Test: @test, @testset

include("compilation.jl")

"""
Seconds `f()` takes outside garbage collection. Full collections scan whole heap, so their cost grows with live data.
Collector stays on: off, large runs hold every allocation in memory.
"""
function quiet(f::Function)::Float64
    GC.gc()
    stats = @timed f()
    return stats.time - stats.gctime
end

"""
Package source with iterator that misses `length`, array struct, string struct and function that shadows `Base.first`;
`batch` names structs apart.
"""
structs_source(batch::Int)::String = """
struct Countdown$batch
    start::Int
end
Base.iterate(countdown::Countdown$batch, state::Int = countdown.start) = state <= 0 ? nothing : (state, state - 1)
first(countdown::Countdown$batch) = countdown.start
struct Ones$batch <: AbstractVector{Float64}
    length::Int
end
Base.size(ones::Ones$batch) = (ones.length,)
Base.getindex(::Ones$batch, ::Int) = 1.0
struct Letters$batch <: AbstractString
    text::String
end
Base.ncodeunits(letters::Letters$batch) = ncodeunits(letters.text)
Base.codeunit(letters::Letters$batch, index::Int) = codeunit(letters.text, index)
Base.isvalid(letters::Letters$batch, index::Int) = isvalid(letters.text, index)
Base.iterate(letters::Letters$batch, index::Int = 1) = iterate(letters.text, index)
"""

"""Fastest of `runs` timings of `f()` in seconds, after one warm-up call."""
function fastest(f::Function, runs::Int)::Float64
    f()
    return minimum(quiet(f) for _ in 1:runs)
end

@testset "speed" begin
    @testset "syntax run inside budget" begin
        # Budget: 2 s per 10,000 lines (plan.md). Measured 0.04 s.
        sources = Corset.Discovery.discover(joinpath(dirname(@__DIR__), "lib", "CorsetLegacy", "src"); environment = nothing)
        texts = [(file.path, file.text, file.role) for file in sources.files]
        lines = sum(((_, text, _),) -> count(==('\n'), text), texts)
        seconds = fastest(3) do
            Corset.Engine.run_rules(FactSet([Corset.Syntax.parse_file(path, text, role) for (path, text, role) in texts], sources.entries, Corset.Facts.Ban[], nothing, nothing, nothing, nothing, nothing, nothing))
        end
        @test seconds * 10_000 / lines < 2.0
    end
    @testset "method sites sort without printing signatures" begin
        # Sort once printed signatures in every comparison; printing type searches loaded modules for alias.
        # Measured 7977 bytes per method; printing sort took 2.6 MB per method.
        mktempdir(@__DIR__; prefix = ".jl_") do directory
            path = joinpath(directory, "Sites.jl")
            write(path, join(("f$index(x::Vector{Int}, y::Dict{String, Float64}) = x" for index in 1:300), "\n"))
            mod = Module(:Sites)
            Base.include(mod, path)
            files = [Corset.Syntax.parse_file(path, read(path, String), Role.package)]
            methods = Corset.Package.module_methods([mod])
            Corset.Package.method_sites(methods, files)
            @test (@allocated Corset.Package.method_sites(methods, files)) / 300 < 16_000
        end
    end
    @testset "argument uses linear in chain of locals" begin
        # Each local reads local before it twice: constant lookup without index doubles per local, 256× from 8 to 16.
        uses = map((8, 16)) do count
            chain = join(("layer$index = Union{layer$(index - 1), layer$(index - 1)}" for index in 1:count), "\n")
            mod = Module(:Chain)
            Base.include_string(mod, "function chained(items::Vector{Int})\nlayer0 = Int\n$chain\nreturn Vector{layer$count}(items)\nend\n")
            bodies = Corset.Package.lowered_bodies(Corset.Package.module_methods([mod]))
            return () -> Corset.Package.argument_uses(bodies, Set([mod]))
        end
        foreach(run -> run(), uses)
        @test (@allocated last(uses)()) / (@allocated first(uses)()) < 8
    end
    @testset "package facts compile independent of package" begin
        # Closure over type value, `Ref(type)`, `Some(value)` and hash set of types compiled again for each type.
        # Measured `package_facts` on Distributions: 116 s cold, 1.8 s warm.
        mktempdir(@__DIR__; prefix = ".jl_") do directory
            facts = map(1:2) do batch
                source = """
                struct Point$batch
                    x::Int
                end
                struct Box$batch{T}
                    items::Vector{T}
                end
                moved(point::Point$batch, step::Int) = Point$batch(point.x + step)
                scaled(point::Point$batch, factor::Int = 2; offset::Int = 0) = moved(point, factor + offset)
                mapped(box::Box$batch, f::Function) = Box$batch(map(item -> f(item), box.items))
                """
                path = joinpath(directory, "Batch$batch.jl")
                write(path, source)
                mod = Module(Symbol(:Batch, batch))
                Base.include(mod, path)
                files = [Corset.Syntax.parse_file(path, source, Role.package)]
                # `names` in running function misses bindings `include` adds later; newest world sees them.
                return () -> Base.invokelatest(Corset.Package.package_facts, [mod], files)
            end
            first(facts)()
            before = specializations(Corset, Base)
            last(facts)()
            @test specializations(Corset, Base) == before
        end
    end
    @testset "inference and effects compile independent of package" begin
        # Closures over unit signature (`offset_signature`) and callee (`call_verdicts!`) compiled again for each value.
        # Measured on Distributions after PDMats: 337 signature closures, 63 callee closures.
        mktempdir(@__DIR__; prefix = ".jl_") do directory
            stages = map(1:2) do batch
                source = """
                first_item(items::AbstractVector{Int}) = items[1]
                fail(x::Int) = throw(ArgumentError("negative"))
                checked(x::Int) = x >= 0 ? x : fail(x)
                """
                path = joinpath(directory, "Stages$batch.jl")
                write(path, source)
                mod = Module(Symbol(:Stages, batch))
                Base.include(mod, path)
                files = [Corset.Syntax.parse_file(path, source, Role.package)]
                # `names` in running function misses bindings `include` adds later; newest world sees them.
                return () -> Base.invokelatest() do
                    package = Corset.Package.package_facts([mod], files)
                    return Corset.Effects.effects_facts(package, Corset.Inference.infer_package(package, files, nothing, nothing)[3], nothing, Corset.Effects.Summaries.Library())
                end
            end
            first(stages)()
            before = specializations(Corset, Base)
            last(stages)()
            @test specializations(Corset, Base) == before
        end
    end
    @testset "package rules compile independent of struct count" begin
        RULES = [Symbol("missing-interface"), Symbol("shadowed-base")]
        # Closure over type value compiles once per value: missing-interface and shadowed-base compiled again for each type.
        mktempdir(@__DIR__; prefix = ".jl_") do directory
            facts = map(1:2) do batch
                path = joinpath(directory, "Structs$batch.jl")
                write(path, structs_source(batch))
                mod = Module(Symbol(:Structs, batch))
                Base.include(mod, path)
                files = [Corset.Syntax.parse_file(path, read(path, String), Role.package)]
                # `names` in running function misses bindings `include` adds later; newest world sees them.
                package = Base.invokelatest(Corset.Package.package_facts, [mod], files)
                return FactSet(files, String[], Corset.Facts.Ban[], nothing, package, nothing, nothing, nothing, nothing)
            end
            rules(facts::FactSet)::Vector{Symbol} = sort!([finding.rule for finding in Base.invokelatest(Corset.Engine.run_rules, facts) if finding.rule in RULES])
            @test rules(first(facts)) == RULES
            before = specializations(Corset)
            @test rules(last(facts)) == RULES
            @test specializations(Corset) == before
        end
    end
    @testset "effects rules compile independent of package" begin
        # `bang-convention` closure over function value and `one-based-range` table keyed by `Type` compiled per value.
        # Cold self-lint on main: 81 s and 29 s of 189 s.
        entries = filter(entry -> entry.name in (Symbol("bang-convention"), Symbol("one-based-range")), Corset.Rules.REGISTRY)
        mktempdir(@__DIR__; prefix = ".jl_") do directory
            facts = map(1:2) do batch
                source = """
                first_item(items::AbstractVector{Int}) = items[1]
                reset_first(items::Vector{Int}) = (items[1] = 0; nothing)
                item_at(items::AbstractVector{Int}, index::Int) = items[index]
                item_through(items::AbstractVector{Int}, index::Int) = item_at(items, index)
                """
                path = joinpath(directory, "Rules$batch.jl")
                write(path, source)
                mod = Module(Symbol(:Rules, batch))
                Base.include(mod, path)
                files = [Corset.Syntax.parse_file(path, source, Role.package)]
                # `names` in running function misses bindings `include` adds later; newest world sees them.
                return Base.invokelatest() do
                    package = Corset.Package.package_facts([mod], files)
                    inference, _, units, _ = Corset.Inference.infer_package(package, files, nothing, nothing)
                    return FactSet(files, String[], Corset.Facts.Ban[], nothing, package, inference, Corset.Effects.effects_facts(package, units, nothing, Corset.Effects.Summaries.Library()).facts, nothing, nothing)
                end
            end
            rules(facts::FactSet)::Vector{Symbol} = sort!([finding.rule for finding in Base.invokelatest(Corset.Engine.run_rules, facts, entries)])
            found = rules(first(facts))
            @test Symbol("bang-convention") in found
            before = specializations(Corset, Base)
            @test rules(last(facts)) == found
            @test specializations(Corset, Base) == before
        end
        # Store record holds signature as new `UnionAll`: equal signature built apart finds same contracts.
        apart = (Corset.Rules.OneBasedRange.Signature(Tuple{typeof(sin), Vector{T}} where {T}) for _ in 1:2)
        @test allequal(apart) && allequal(hash.(apart))
    end
    @testset "cost linear in function size" begin
        # Every UI and opt-out case inside one function, 16 and 128 copies: linear cost grows 8×, quadratic 64×.
        # Both sizes exceed processor cache: smaller trees fit in it, and cache step looks like superlinear time.
        ui = [case for rule in readdir(joinpath(@__DIR__, "ui"); join = true) for case in readdir(rule; join = true) if endswith(case, ".jl")]
        cases = join((read(case, String) for case in [ui; joinpath(@__DIR__, "optout", "cases.jl")]), "\n")
        mktempdir(@__DIR__; prefix = ".jl_") do directory
            small, large = map((16, 128)) do copies
                path = joinpath(directory, "copies_$copies.jl")
                write(path, "function wrapped()\n$(repeat(cases, copies))end\n")
                return path
            end
            bans = Corset.Config.bans(Corset.Config.read_table(joinpath(@__DIR__, "ui", "banned", "config.toml"), ("Corset",)))
            facts = Dict(path => FactSet([Corset.Syntax.parse_file(path, read(path, String), Role.package)], [path], bans, nothing, nothing, nothing, nothing, nothing, nothing) for path in (small, large))
            findings = Dict(path => Corset.Engine.run_rules(facts[path]) for path in (small, large))
            known = Set(entry.name for entry in Corset.Rules.REGISTRY)
            stages = Dict{String, Function}(
                "parse" => path -> Corset.Syntax.parse_file(path, read(path, String), Role.package),
                "rules" => path -> Corset.Engine.run_rules(facts[path]),
                "opt-outs" => path -> Corset.OptOuts.apply(facts[path], findings[path], known),
                "baseline" => path -> Corset.Baseline.finding_keys(facts[path], directory, findings[path]),
            )
            # Allocation growth is deterministic: every rule, stage and whole run gets 2× headroom over linear.
            growth(f::Function)::Float64 = (f(small); @allocated(f(large)) / @allocated(f(small)))
            growths = Dict(string(entry.name) => growth(path -> entry.run(facts[path])) for entry in Corset.Rules.REGISTRY)
            merge!(growths, Dict(name => growth(stage) for (name, stage) in stages), Dict("analyze" => growth(path -> Corset.Engine.analysis(path, Corset.Config.Flags(), nothing, nothing, nothing))))
            @test isempty(filter(entry -> last(entry) >= 16, growths))
            # Time catches loops that do not allocate. Load swings ratio of same input from 4 to 9, so time gets 5× headroom.
            # Single rules visit few nodes: cache misses swing their time.
            @test isempty(filter(entry -> last(entry) >= 40, Dict(name => fastest(() -> stage(large), 3) / fastest(() -> stage(small), 3) for (name, stage) in stages)))
        end
    end
end
