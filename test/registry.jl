# Registry agrees with design data, and rule files keep rule contract.

using Corset: Corset
using Corset.Facts: Group, Stage, Role
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

@testset "rules tolerate quoted operators" begin
    # Quoted syntactic operators parse as leaves of form kinds; index skips them as quoted code, tree walks see them.
    text = """
    ops = [:(=), :(::), :(->), :(&&), :(||), :(.=), :(+=), :(<:), :(>:), :(.), :(\$), :(...)]
    function quoted(expression)
        expression.head === :(=) && return :(::)
        return expression
    end
    """
    file = Corset.Syntax.parse_file("quoted.jl", text, Role.package)
    @test length(Corset.Facts.forms(file, "=")) == 1
    @test isempty(Corset.Facts.leaves(file, "="))
    facts = Corset.Facts.FactSet([file], String[], Corset.Facts.Ban[], nothing, nothing, nothing, nothing, nothing, nothing)
    for entry in Corset.Rules.REGISTRY
        @test entry.run(facts) isa Vector{Corset.Facts.Finding}
    end
end

@testset "registry in name order" begin
    @test issorted([entry.name for entry in Corset.Rules.REGISTRY])
end

@testset "rule files import only Facts" begin
    directory = joinpath(dirname(@__DIR__), "src", "rules")
    for name in filter(endswith(".jl"), readdir(directory))
        path = joinpath(directory, name)
        # Parsed statements only: docstring examples may show `using`.
        file = Corset.Syntax.parse_file(path, read(path, String), Role.package)
        @test [Corset.Facts.source(file, node) for kind in ("using", "import") for node in Corset.Facts.forms(file, kind)] == ["using ...Facts"]
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
