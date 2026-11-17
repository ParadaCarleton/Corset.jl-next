# Speed: syntax budget on legacy source, and cost linear in function size.

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
            Corset.Engine.run_rules(FactSet([Corset.Syntax.parse_file(path, text, role) for (path, text, role) in texts], sources.entries, Corset.Facts.Ban[], nothing, nothing, nothing, nothing, nothing))
        end
        @test seconds * 10_000 / lines < 2.0
    end
    @testset "method sites sort without printing signatures" begin
        # Sort once printed signatures in every comparison; printing type searches loaded modules for alias.
        # Measured 7977 bytes per method; printing sort took 2.6 MB per method.
        mktempdir(@__DIR__) do directory
            path = joinpath(directory, "Sites.jl")
            write(path, join(("f$index(x::Vector{Int}, y::Dict{String, Float64}) = x" for index in 1:300), "\n"))
            mod = Module(:Sites)
            Base.include(mod, path)
            files = [Corset.Syntax.parse_file(path, read(path, String), Role.package)]
            Corset.Package.method_sites([mod], files)
            @test (@allocated Corset.Package.method_sites([mod], files)) / 300 < 16_000
        end
    end
    @testset "package rules compile independent of struct count" begin
        RULES = [Symbol("missing-interface"), Symbol("shadowed-base")]
        # Closure over type value compiles once per value: missing-interface and shadowed-base compiled again for each type.
        mktempdir(@__DIR__) do directory
            facts = map(1:2) do batch
                path = joinpath(directory, "Structs$batch.jl")
                write(path, structs_source(batch))
                mod = Module(Symbol(:Structs, batch))
                Base.include(mod, path)
                files = [Corset.Syntax.parse_file(path, read(path, String), Role.package)]
                # `names` in running function misses bindings `include` adds later; newest world sees them.
                package = Base.invokelatest(Corset.Package.package_facts, [mod], files)
                return FactSet(files, String[], Corset.Facts.Ban[], nothing, package, nothing, nothing, nothing)
            end
            rules(facts::FactSet)::Vector{Symbol} = sort!([finding.rule for finding in Base.invokelatest(Corset.Engine.run_rules, facts) if finding.rule in RULES])
            @test rules(first(facts)) == RULES
            before = specializations(Corset)
            @test rules(last(facts)) == RULES
            @test specializations(Corset) == before
        end
    end
    @testset "cost linear in function size" begin
        # Every UI and opt-out case inside one function, 16 and 128 copies: linear cost grows 8×, quadratic 64×.
        # Both sizes exceed processor cache: smaller trees fit in it, and cache step looks like superlinear time.
        ui = [case for rule in readdir(joinpath(@__DIR__, "ui"); join = true) for case in readdir(rule; join = true) if endswith(case, ".jl")]
        cases = join((read(case, String) for case in [ui; joinpath(@__DIR__, "optout", "cases.jl")]), "\n")
        mktempdir(@__DIR__) do directory
            small, large = map((16, 128)) do copies
                path = joinpath(directory, "copies_$copies.jl")
                write(path, "function wrapped()\n$(repeat(cases, copies))end\n")
                return path
            end
            bans = Corset.Config.bans(Corset.Config.read_table(joinpath(@__DIR__, "ui", "banned", "config.toml"), ("Corset",)))
            facts = Dict(path => FactSet([Corset.Syntax.parse_file(path, read(path, String), Role.package)], [path], bans, nothing, nothing, nothing, nothing, nothing) for path in (small, large))
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
            merge!(growths, Dict(name => growth(stage) for (name, stage) in stages), Dict("analyze" => growth(path -> Corset.Engine.analysis(path, Corset.Config.Flags(), nothing, nothing))))
            @test isempty(filter(entry -> last(entry) >= 16, growths))
            # Time catches loops that do not allocate. Load swings ratio of same input from 4 to 9, so time gets 5× headroom.
            # Single rules visit few nodes: cache misses swing their time.
            @test isempty(filter(entry -> last(entry) >= 40, Dict(name => fastest(() -> stage(large), 3) / fastest(() -> stage(small), 3) for (name, stage) in stages)))
        end
    end
end
