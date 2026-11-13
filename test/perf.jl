# Speed: syntax budget on legacy source, and cost linear in function size.

using Corset: Corset
using Corset.Facts: FactSet
using Test: @test, @testset

"""Seconds `f()` takes with garbage collector off: full collections scan whole heap, so their cost grows with live data."""
function quiet(f::Function)::Float64
    GC.gc(false)
    GC.enable(false)
    try
        return @elapsed f()
    finally
        GC.enable(true)
    end
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
        texts = [(file.path, file.text) for file in sources.files]
        lines = sum(text -> count(==('\n'), text), last.(texts))
        seconds = fastest(3) do
            Corset.Engine.run_rules(FactSet([Corset.Syntax.parse_file(path, text) for (path, text) in texts], sources.entries))
        end
        @test seconds * 10_000 / lines < 2.0
    end
    @testset "cost linear in function size" begin
        # Every UI and opt-out case inside one function, 2 and 32 copies: linear cost grows 16×, quadratic 256×.
        ui = [case for rule in readdir(joinpath(@__DIR__, "ui"); join = true) for case in readdir(rule; join = true) if endswith(case, ".jl")]
        cases = join((read(case, String) for case in [ui; joinpath(@__DIR__, "optout", "cases.jl")]), "\n")
        mktempdir(@__DIR__) do directory
            small, large = map((2, 32)) do copies
                path = joinpath(directory, "copies_$copies.jl")
                write(path, "function wrapped()\n$(repeat(cases, copies))end\n")
                return path
            end
            # Time ratio gets 5× headroom over linear; allocation ratio is deterministic and gets 2×.
            ratios(f::Function) = (fastest(() -> f(large), 5) / fastest(() -> f(small), 5), @allocated(f(large)) / @allocated(f(small)))
            facts = Dict(path => FactSet([Corset.Syntax.parse_file(path, read(path, String))], [path]) for path in (small, large))
            measured = Dict(string(entry.name) => ratios(path -> entry.run(facts[path])) for entry in Corset.Rules.REGISTRY)
            measured["parse"] = ratios(path -> Corset.Syntax.parse_file(path, read(path, String)))
            # Measure stages after rules alone: inside `analyze`, linear rule cost hides their growth.
            findings = Dict(path => Corset.Engine.run_rules(facts[path]) for path in (small, large))
            known = Set(entry.name for entry in Corset.Rules.REGISTRY)
            measured["opt-outs"] = ratios(path -> Corset.OptOuts.apply(facts[path], findings[path], known))
            measured["baseline"] = ratios(path -> Corset.Baseline.finding_keys(facts[path], directory, findings[path]))
            measured["analyze"] = ratios(path -> Corset.Engine.analyze(path, Corset.Config.Flags()))
            @test isempty(filter(entry -> first(last(entry)) >= 80 || last(last(entry)) >= 32, measured))
        end
    end
end
