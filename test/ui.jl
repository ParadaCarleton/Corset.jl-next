# UI snapshot tests, as in Clippy: test/ui/<rule>/<case>.jl, rendered output in <case>.out,
# fixed source in <case>.fixed.jl; package case puts each changed file there under `# ==> <path>` line.
# Set CORSET_BLESS=1 to rewrite snapshots.
# Package case is directory test/ui/<rule>/<case>/; package loads only for rule after `syntax` stage.
# Each case file starts with `# runic: off`: formatter must not normalize syntax cases test.

using Corset: Corset
using Corset.Facts: FactSet, Tier, Confidence, Role, Ban, Stage
using Corset.Config: Settings, Kind, Level
using Test: @test, @testset
using TOML: TOML

const UI = joinpath(@__DIR__, "ui")
const BLESS = get(ENV, "CORSET_BLESS", "") == "1"
"""Settings UI cases render under: library preset with restriction rules on, both confidences."""
const UI_SETTINGS = Settings(Kind.library, Confidence.possible, Tier.breaking, Dict("restriction" => (Level.warn, "UI cases")), false, Ban[], false)

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
    return FactSet([file], [file.path], case_bans(dirname(case)), nothing, nothing, nothing, nothing, nothing)
end

"""
Facts of package directory `case` for rule of `stage`. Package loads, with case directory added to load path, for
stage after `syntax`; fixture must load. Inference and external facts exist for their own stage only.
"""
function package_facts(case::String, stage::Stage.T)::FactSet
    sources = Corset.Discovery.discover(case; environment = nothing)
    stage == Stage.syntax && return FactSet(sources.files, sources.entries, case_bans(dirname(case)), sources.project, nothing, nothing, nothing, nothing)
    push!(LOAD_PATH, case)
    loaded = try
        Corset.Package.load(sources.project, sources.files)
    finally
        pop!(LOAD_PATH)
    end
    isempty(loaded.errors) || error("fixture $case does not load: $(first(loaded.errors).primary.text)")
    inference = stage == Stage.inference ? first(Corset.Inference.inference_facts(loaded.facts, sources.files, nothing, nothing)) : nothing
    external = stage == Stage.external ? Corset.External.external_facts(loaded.facts, sources.project.entry, sources.files) : nothing
    return FactSet(sources.files, sources.entries, case_bans(dirname(case)), sources.project, loaded.facts, inference, nothing, external)
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
    facts = isdir(case) ? package_facts(case, Corset.Rules.entry(name).fix_stage) : file_facts(case)
    findings = Corset.Engine.run_rules(facts, [Corset.Rules.entry(name)])
    sources = Dict(file.path => file.text for file in facts.files)
    root = isdir(case) ? case : dirname(case)
    report = Corset.Engine.Report(Corset.Engine.diagnostics(findings, UI_SETTINGS), UI_SETTINGS, root, sources, length(sources), 0, [], [])
    rendered = sprint(io -> Corset.Render.render_all(io, report))
    return rendered, fixed_text(Corset.Fixes.applicable_edits(findings, Tier.breaking), sources, root, isdir(case))
end

"""
Copy of package `case` in `directory` with `edits` applied, renamed `<name>Fixed` with new uuid, so it loads beside
original and earlier copies. Copy keeps name of `case` when `case` is copy already. Returns path of copy.
"""
function fixed_package(case::String, edits::Vector{Corset.Facts.Edit}, directory::String)::String
    project = TOML.parsefile(joinpath(case, "Project.toml"))
    name = project["name"]
    copy = joinpath(directory, "$(name)Fixed$(length(readdir(directory)))")
    cp(case, copy)
    for file in unique(edit.span.file for edit in edits)
        write(joinpath(copy, relpath(file, case)), Corset.Fixes.apply_edits(read(file, String), filter(edit -> edit.span.file == file, edits)))
    end
    fixed = basename(copy)
    entry = joinpath(copy, "src", name * ".jl")
    write(joinpath(copy, "src", fixed * ".jl"), replace(read(entry, String), "module $name\n" => "module $fixed\n"))
    rm(entry)
    project["name"], project["uuid"] = fixed, string(Base.UUID(rand(UInt128)))
    open(io -> TOML.print(io, project), joinpath(copy, "Project.toml"), "w")
    return copy
end

"""Most fix rounds fixes of one case may take: annotation guess of argument lets next run guess result."""
const FIX_ROUNDS = 3

"""Package cases of rules whose fixes rest on inference (`fix_stage`); fixed package must lose each fixed finding."""
const INFERENCE_CASES = [
    (rule, case) for rule in sort!(readdir(UI)) if Corset.Rules.entry(Symbol(rule)).fix_stage == Stage.inference
        for case in sort!(readdir(joinpath(UI, rule))) if isdir(joinpath(UI, rule, case))
]

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

@testset "UI $(rule) $(name) fixes converge" for (rule, name) in INFERENCE_CASES
    entry, case = Corset.Rules.entry(Symbol(rule)), joinpath(UI, rule, name)
    fixable(found::Vector{Corset.Facts.Finding})::Bool = any(finding -> !isnothing(finding.fix) && finding.fix.tier != Tier.manual, found)
    mktempdir() do directory
        findings = Corset.Engine.run_rules(package_facts(case, entry.fix_stage), [entry])
        initial, rounds = length(findings), 0
        while fixable(findings) && rounds < FIX_ROUNDS
            case, rounds = fixed_package(case, Corset.Fixes.applicable_edits(findings, Tier.breaking), directory), rounds + 1
            findings = Corset.Engine.run_rules(package_facts(case, entry.fix_stage), [entry])
        end
        @test !fixable(findings)
        @test length(findings) <= initial
    end
end

@testset "every rule has UI tests" begin
    @test sort!([string(entry.name) for entry in Corset.Rules.REGISTRY]) == sort!(readdir(UI))
end
