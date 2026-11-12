# Registry agrees with design data, and rule files keep rule contract.

using Corset: Corset
using Corset.Facts: Group, Stage
using TOML: TOML
using Test: @test, @testset

const DESIGN = joinpath(dirname(@__DIR__), "docs", "design")
"""Stage names in pipeline order; rule belongs to last stage among its footguns."""
const STAGES = [entry["name"] for entry in TOML.parsefile(joinpath(DESIGN, "stages.toml"))["stage"]]

@testset "registry matches design" begin
    footguns = Dict(entry["id"] => entry for entry in TOML.parsefile(joinpath(DESIGN, "footguns.toml"))["footgun"])
    rules = Dict(Symbol(entry["name"]) => entry for entry in TOML.parsefile(joinpath(DESIGN, "rules.toml"))["rule"])
    for entry in Corset.Rules.REGISTRY
        @test haskey(rules, entry.name)
        design = rules[entry.name]
        @test entry.footguns == design["footguns"]
        @test string(entry.group) == footguns[first(entry.footguns)]["group"]
        @test string(entry.stage) == argmax(name -> findfirst(==(name), STAGES), [footguns[id]["stage"] for id in entry.footguns])
    end
end

@testset "registry in name order" begin
    @test issorted([entry.name for entry in Corset.Rules.REGISTRY])
end

@testset "rule files import only Facts" begin
    directory = joinpath(dirname(@__DIR__), "src", "rules")
    for name in filter(endswith(".jl"), readdir(directory))
        imports = filter(line -> occursin(r"^\s*(using|import)\b", line), readlines(joinpath(directory, name)))
        @test imports == ["using ...Facts"]
    end
end

@testset "rule docs follow Clippy sections" begin
    for entry in Corset.Rules.REGISTRY
        doc = Corset.CLI.module_doc(parentmodule(entry.run))
        @test startswith(doc, "`$(entry.name)` (")
        positions = [findfirst("\n## $section\n", doc) for section in ("Description", "Rationale", "Example", "Alternative", "Limitations")]
        @test all(!isnothing, positions) && issorted(first.(positions))
    end
end
