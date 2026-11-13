# Speed: syntax budget on legacy source, and cost linear in function size.

using Corset: Corset
using Corset.Facts: FactSet, Role
using Test: @test, @testset

"""
Seconds `f()` takes outside garbage collection. Full collections scan whole heap, so their cost grows with live data.
Collector stays on: off, large runs hold every allocation in memory.
"""
function quiet(f::Function)::Float64
    GC.gc()
    stats = @timed f()
    return stats.time - stats.gctime
end

"""Fastest of `runs` timings of `f()` in seconds, after one warm-up call."""
function fastest(f::Function, runs::Int)::Float64
    f()
    return minimum(quiet(f) for _ in 1:runs)
end

@testset "speed" begin
    @testset "syntax run inside budget" begin
        # Budget: 2 s per 10,000 lines (plan.md). Measured 0.04 s.
        sources = Corset.Discovery.discover(joinpath(dirname(@__DIR__), "lib", "CorsetLegacy", "src"))
        texts = [(file.path, file.text, file.role) for file in sources.files]
        lines = sum(((_, text, _),) -> count(==('\n'), text), texts)
        seconds = fastest(3) do
            Corset.Engine.run_rules(FactSet([Corset.Syntax.parse_file(path, text, role) for (path, text, role) in texts], sources.entries))
        end
        @test seconds * 10_000 / lines < 2.0
    end
    @testset "cost linear in function size" begin
        # Every UI and opt-out case inside one function, 16 and 64 copies: linear cost grows 4×, quadratic 16×.
        # Both sizes exceed processor cache: smaller trees fit in it, and cache step looks like superlinear time.
        ui = [case for rule in readdir(joinpath(@__DIR__, "ui"); join = true) for case in readdir(rule; join = true) if endswith(case, ".jl")]
        cases = join((read(case, String) for case in [ui; joinpath(@__DIR__, "optout", "cases.jl")]), "\n")
        mktempdir(@__DIR__) do directory
            small, large = map((16, 64)) do copies
                path = joinpath(directory, "copies_$copies.jl")
                write(path, "function wrapped()\n$(repeat(cases, copies))end\n")
                return path
            end
            facts = Dict(path => FactSet([Corset.Syntax.parse_file(path, read(path, String), Role.package)], [path]) for path in (small, large))
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
            merge!(growths, Dict(name => growth(stage) for (name, stage) in stages), Dict("analyze" => growth(path -> Corset.Engine.analyze(path, Corset.Config.Flags()))))
            @test isempty(filter(entry -> last(entry) >= 8, growths))
            # Time catches loops that do not allocate; it gets 2.5× headroom. Single rules visit few nodes: cache misses swing their time.
            @test isempty(filter(entry -> last(entry) >= 10, Dict(name => fastest(() -> stage(large), 3) / fastest(() -> stage(small), 3) for (name, stage) in stages)))
        end
    end
end
