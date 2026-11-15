# UI snapshot tests, as in Clippy: test/ui/<rule>/<case>.jl, rendered output in <case>.out,
# fixed source in <case>.fixed.jl; package case puts each changed file there under `# ==> <path>` line.
# Set CORSET_BLESS=1 to rewrite snapshots.
# Package case is directory test/ui/<rule>/<case>/; package loads only for rule after `syntax` stage.
# Each case file starts with `# runic: off`: formatter must not normalize syntax cases test.

using Corset: Corset
using Corset.Facts: FactSet, Tier, Confidence, Role, Ban, Stage
using Corset.Config: Settings, Kind
using Test: @test, @testset

const UI = joinpath(@__DIR__, "ui")
const BLESS = get(ENV, "CORSET_BLESS", "") == "1"
"""Settings UI cases render under: library preset, both confidences."""
const UI_SETTINGS = Settings(Kind.library, Confidence.possible, Tier.breaking, Dict(), false, Ban[])

"""Bans of `[Corset]` table in `config.toml` next to case, as LocalPreferences.toml holds them; none without file."""
case_bans(directory::String)::Vector{Ban} = Corset.Config.bans(Corset.Config.read_table(joinpath(directory, "config.toml"), ("Corset",)))

"""Compare `actual` with snapshot `path`; write it when blessing. Missing snapshot means empty expected text."""
function snapshot(path::String, actual::String)::Bool
    BLESS && (isempty(actual) ? (isfile(path) && rm(path)) : write(path, actual))
    return actual == (isfile(path) ? read(path, String) : "")
end

"""Facts of file `case`, as in `corset check case.jl`: `script*.jl` parses as script, other files as package code."""
function file_facts(case::String)::FactSet
    file = Corset.Syntax.parse_file(case, read(case, String), startswith(basename(case), "script") ? Role.script : Role.package)
    return FactSet([file], [file.path], case_bans(dirname(case)), nothing, nothing, nothing, nothing)
end

"""
Facts of package directory `case` for rule of `stage`. Package loads, with case directory added to load path, for
stage after `syntax`; fixture must load. Inference and external facts exist for their own stage only.
"""
function package_facts(case::String, stage::Stage.T)::FactSet
    sources = Corset.Discovery.discover(case; environment = nothing)
    stage == Stage.syntax && return FactSet(sources.files, sources.entries, case_bans(dirname(case)), sources.project, nothing, nothing, nothing)
    push!(LOAD_PATH, case)
    loaded = try
        Corset.Package.load(sources.project, sources.files)
    finally
        pop!(LOAD_PATH)
    end
    isempty(loaded.errors) || error("fixture $case does not load: $(first(loaded.errors).primary.text)")
    inference = stage == Stage.inference ? first(Corset.Inference.inference_facts(loaded.facts, sources.files)) : nothing
    external = stage == Stage.external ? Corset.External.external_facts(loaded.facts, sources.project.entry, sources.files) : nothing
    return FactSet(sources.files, sources.entries, case_bans(dirname(case)), sources.project, loaded.facts, inference, external)
end

"""Source file of `case` that must start with `# runic: off`: case file, or module file of package case."""
case_file(case::String)::String = isdir(case) ? first(Corset.Discovery.discover(case; environment = nothing).entries) : case

"""
Fixed text of every file `edits` change, from `sources`: file case gives its text; package case gives each file under
`# ==> <path>` line, path relative to `root`, in path order. No edit gives empty text.
"""
function fixed_text(edits::Vector{Corset.Facts.Edit}, sources::Dict{String, String}, root::String, package::Bool)::String
    files = sort!(unique(edit.span.file for edit in edits))
    fixed = [Corset.Fixes.apply_edits(sources[file], filter(edit -> edit.span.file == file, edits)) for file in files]
    package || return isempty(fixed) ? "" : only(fixed)
    return join("# ==> $(relpath(file, root))\n$text" for (file, text) in zip(files, fixed))
end

"""
Rendered findings and fixed source for `case` of rule `name`. File case is only entry; directory case is package.
Bans come from `case_bans`.
"""
function run_case(name::Symbol, case::String)::Tuple{String, String}
    facts = isdir(case) ? package_facts(case, Corset.Rules.entry(name).stage) : file_facts(case)
    findings = Corset.Engine.run_rules(facts, [Corset.Rules.entry(name)])
    sources = Dict(file.path => file.text for file in facts.files)
    root = isdir(case) ? case : dirname(case)
    report = Corset.Engine.Report(Corset.Engine.diagnostics(findings, UI_SETTINGS), UI_SETTINGS, root, sources, length(sources), 0, [], [])
    rendered = sprint(io -> Corset.Render.render_all(io, report))
    return rendered, fixed_text(Corset.Fixes.applicable_edits(findings, Tier.breaking), sources, root, isdir(case))
end

@testset "UI $(rule)" for rule in sort!(readdir(UI))
    directory = joinpath(UI, rule)
    cases = sort!(filter(name -> isdir(joinpath(directory, name)) || endswith(name, ".jl") && !endswith(name, ".fixed.jl"), readdir(directory)))
    stems = map(case -> chopsuffix(case, ".jl"), cases)
    @test "positive" in stems
    @test "negative" in stems
    for (case, stem) in zip(cases, stems)
        path = joinpath(directory, case)
        @test startswith(read(case_file(path), String), "# runic: off\n")
        rendered, fixed = run_case(Symbol(rule), path)
        @test snapshot(joinpath(directory, stem * ".out"), rendered)
        @test snapshot(joinpath(directory, stem * ".fixed.jl"), fixed)
        stem == "negative" && @test isempty(rendered)
        stem == "positive" && @test !isempty(rendered)
    end
end

@testset "every rule has UI tests" begin
    @test sort!([string(entry.name) for entry in Corset.Rules.REGISTRY]) == sort!(readdir(UI))
end
