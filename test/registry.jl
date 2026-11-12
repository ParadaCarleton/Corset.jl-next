# Registry agrees with design data, and check files keep check contract.

using Corset: Corset
using Corset.Facts: Group, Family
using TOML: TOML
using Test: @test, @testset

const DESIGN = joinpath(dirname(@__DIR__), "docs", "design")

@testset "registry matches design" begin
    footguns = Dict(entry["id"] => entry for entry in TOML.parsefile(joinpath(DESIGN, "footguns.toml"))["footgun"])
    checks = Dict(Symbol(entry["name"]) => entry for entry in TOML.parsefile(joinpath(DESIGN, "checks.toml"))["check"])
    for entry in Corset.Checks.REGISTRY
        @test haskey(checks, entry.name)
        design = checks[entry.name]
        @test entry.footguns == design["footguns"]
        @test string(entry.group) == footguns[first(entry.footguns)]["group"]
        @test string(entry.family) in [footguns[id]["family"] for id in entry.footguns]
    end
end

@testset "check files import only Facts" begin
    directory = joinpath(dirname(@__DIR__), "src", "checks")
    for name in readdir(directory)
        imports = filter(line -> occursin(r"^\s*(using|import)\b", line), readlines(joinpath(directory, name)))
        @test imports == ["using ...Facts"]
    end
end
