# Unit tests for skeleton pieces that UI snapshots do not reach.

using Corset: Corset
using Corset.Facts: Facts, Span, Label, Edit, Fix, Finding, Precision, Tier, Confidence, Group, IndexedPattern, @pattern
using Corset.Config: Config, ConfigError, Flags, Kind, Level, Settings
using Corset.Engine: Diagnostic, Report
using Corset.Rules: REGISTRY, entry
using Test: @test, @testset, @test_throws

"""Finding in file `name` with primary span `bytes`, causes `causes` and fix `fix`."""
function sample_finding(bytes::UnitRange{Int}; precision = Precision.exact, causes = Label[], fix = nothing)::Finding
    return Finding(
        :sample, :kind, Confidence.definite, "headline", Label(Span("f.jl", first(bytes), last(bytes), precision), "primary"),
        causes, "reason", fix,
    )
end

@testset "fixes" begin
    text = "abc def"
    edit(first, last, replacement) = Edit(Span("f.jl", first, last, Precision.exact), replacement)
    @test Corset.Fixes.apply_edits(text, [edit(5, 7, "xyz"), edit(1, 1, "A")]) == "Abc xyz"
    @test_throws ArgumentError Corset.Fixes.apply_edits(text, [edit(1, 3, "x"), edit(3, 4, "y")])
    findings = [
        sample_finding(1:1; fix = Fix("t", [edit(1, 1, "A")], Tier.safe)),
        sample_finding(5:7; fix = Fix("t", [edit(5, 7, "xyz")], Tier.breaking)),
        sample_finding(2:2; fix = Fix("t", Edit[], Tier.manual)),
        sample_finding(3:3),
    ]
    @test length(Corset.Fixes.applicable_edits(findings, "f.jl", Tier.safe)) == 1
    @test length(Corset.Fixes.applicable_edits(findings, "f.jl", Tier.manual)) == 2
    @test isempty(Corset.Fixes.applicable_edits(findings, "other.jl", Tier.manual))
end

@testset "render" begin
    text = "a = 1\nb = 2\nc = 3\nd = 4\ne = 5\n"
    render(finding) = sprint(io -> Corset.Render.render(io, Diagnostic(finding, Level.warn, "test"), text, false))
    adjacent = render(sample_finding(13:17; causes = [Label(Span("f.jl", 1, 5, Precision.exact), "cause")]))
    @test occursin("2 | b = 2", adjacent)
    gap = render(sample_finding(25:29; causes = [Label(Span("f.jl", 1, 5, Precision.exact), "cause")]))
    @test occursin("...", gap)
    whole_line = render(sample_finding(15:15; precision = Precision.line))
    @test occursin("  | ^^^^^ primary", whole_line)
    multi_line = render(sample_finding(1:9))
    @test occursin("  | ^^^^^ primary", multi_line)
    @test Corset.Render.line_text("x\r\n", [1, 4], 1) == "x"
    tabbed = "\ty = 1\n"
    @test occursin("1 |     y = 1\n  |     ^ primary", sprint(io -> Corset.Render.render(io, Diagnostic(sample_finding(2:2), Level.warn, "test"), tabbed, false)))
end

@testset "facts" begin
    @test isnothing(IndexedPattern(@pattern {x}).roots)
    @test isnothing(IndexedPattern(@pattern ~or(f({x}), {y})).roots)
    mixed = IndexedPattern(@pattern ~or(f({x}), g({x}), [], {a}.b({x}), h({x})))
    @test mixed.roots[Corset.Syntax.JS.K"call"] === nothing
    @test mixed.roots[Corset.Syntax.JS.K"vect"] === nothing
    @test IndexedPattern(@pattern ~or(f({x}), g({x}))).roots[Corset.Syntax.JS.K"call"] == Set(["f", "g"])
    file = Corset.Syntax.parse_file("f.jl", "g(1)\n")
    @test length(Facts.matches(file, IndexedPattern(@pattern {x}))) > 1
    @test Facts.identifier_name(only(Facts.leaves(file, "Integer"))) === nothing
    @test isempty(Facts.children_of(only(Facts.leaves(file, "Integer"))))
    text = "a = :(b = 1)\nc = :(f(\$(d = 2)))\n@dsl {e} = 3\n@test (g = 4)\nquote quote \$(h = 5) end end\n"
    quoted = Corset.Syntax.parse_file("q.jl", text)
    @test [Facts.source(quoted, node) for node in Facts.forms(quoted, "=")] == ["a = :(b = 1)", "c = :(f(\$(d = 2)))", "d = 2", "{e} = 3", "g = 4"]
end

@testset "engine" begin
    directory = mktempdir(@__DIR__)
    write(joinpath(directory, "a.jl"), "x ≈ 0\n")
    write(joinpath(directory, "notes.txt"), "x ≈ 0\n")
    @test Corset.Engine.julia_files(directory) == [joinpath(directory, "a.jl")]
    @test Corset.Engine.julia_files(joinpath(directory, "a.jl")) == [joinpath(directory, "a.jl")]
    @test_throws ArgumentError Corset.Engine.julia_files(joinpath(directory, "missing"))
    report = Corset.check(directory)
    @test [diagnostic.finding.rule for diagnostic in report.diagnostics] == [Symbol("approx-zero")]
    @test report.settings.kind == Kind.application
    @test Corset.Engine.failed(report)
    @test_throws ArgumentError Corset.Rules.entry(:no_such_check)
    rm(directory; recursive = true)
end

@testset "pipeline runs on legacy sources" begin
    # Real code finds crashes that fixtures miss; replace this corpus once legacy code is deleted.
    directory = mktempdir(@__DIR__)
    cp(joinpath(dirname(@__DIR__), "lib", "CorsetLegacy", "src"), joinpath(directory, "src"))
    write(joinpath(directory, "Project.toml"), "name = \"Corpus\"\n\n[preferences.Corset]\nkind = \"library\"\n")
    report = Corset.check(directory)
    @test !isempty(report.diagnostics)
    @test isnothing(Corset.Render.render_all(devnull, report))
    @test length(Corset.Output.json_report(report)["diagnostics"]) == length(report.diagnostics)
    @test length(only(Corset.Output.sarif_report(report, "0")["runs"])["results"]) == length(report.diagnostics)
    rm(directory; recursive = true)
end

const CONFIG = joinpath(@__DIR__, "config")

"""Settings of config fixture `name` with command-line `flags`."""
fixture_settings(name::String, flags::Flags = Flags())::Settings = Config.settings(joinpath(CONFIG, name), flags, REGISTRY)

"""Level of rule `name` under `settings`."""
level(settings::Settings, name::String)::Level.T = first(Config.level_of(settings, entry(Symbol(name))))

@testset "config" begin
    library = fixture_settings("library")
    @test (library.kind, library.confidence, library.tier) == (Kind.library, Confidence.possible, Tier.safe)
    @test level(library, "one-letter") == Level.deny
    @test level(library, "file-length") == Level.warn
    @test level(library, "docstring") == Level.allow
    @test level(library, "approx-zero") == Level.deny
    @test level(library, "untyped-empty") == Level.warn
    @test Config.level_of(library, entry(Symbol("one-letter")))[2] == "`one-letter` set in config"
    @test Config.level_of(library, entry(:docstring))[2] == "readability group set in config"
    @test Config.level_of(library, entry(Symbol("approx-zero")))[2] == "correctness group, library preset"
    nameless = fixture_settings("nameless")
    @test (nameless.kind, nameless.confidence, nameless.tier) == (Kind.application, Confidence.definite, Tier.breaking)
    @test fixture_settings("not-table").kind == Kind.application
    for broken in ("missing-kind", "bad-level", "unknown-rule", "unknown-key", "broken-toml")
        @test_throws ConfigError fixture_settings(broken)
    end
    @test sprint(showerror, ConfigError("bad")) == "config error: bad"
    flags = Flags(; levels = ["readability" => Level.deny, "approx-zero" => Level.warn], confidence = Confidence.possible, tier = Tier.safe, deny_warnings = true)
    script = Config.settings(nothing, flags, REGISTRY)
    @test (script.kind, script.confidence, script.tier, script.deny_warnings) == (Kind.script, Confidence.possible, Tier.safe, true)
    @test level(script, "one-letter") == Level.deny
    @test Config.level_of(script, entry(Symbol("approx-zero"))) == (Level.warn, "`approx-zero` set in command line")
    @test level(Config.settings(nothing, Flags(), REGISTRY), "untyped-empty") == Level.allow
    @test_throws ConfigError Config.settings(nothing, Flags(; levels = ["no-such-rule" => Level.deny]), REGISTRY)
    @test Config.preset_level(Kind.application, Group.composability) == Level.allow
    @test Config.project_root(joinpath(CONFIG, "library", "a.jl")) == joinpath(CONFIG, "library")
    @test Config.project_root("/") === nothing
    @test isempty(intersect(string.(instances(Group.T)), [string(rule.name) for rule in REGISTRY]))
end

@testset "levels and report" begin
    report = Corset.check(joinpath(CONFIG, "library"))
    @test [(diagnostic.finding.rule, diagnostic.level) for diagnostic in report.diagnostics] ==
        [(Symbol("untyped-empty"), Level.warn), (Symbol("approx-zero"), Level.deny), (Symbol("approx-zero"), Level.deny)]
    @test Corset.Engine.failed(report)
    rendered = sprint(io -> Corset.Render.render_all(io, report))
    @test startswith(rendered, "warning[untyped-empty]")
    @test occursin("error[approx-zero]", rendered)
    @test count("= note: deny from correctness group, library preset", rendered) == 1
    possible = Finding(
        Symbol("approx-zero"), :kind, Confidence.possible, "m", Label(Span("f.jl", 1, 1, Precision.exact), "l"), Label[], "w", nothing,
    )
    definite_only = Config.settings(nothing, Flags(), REGISTRY)
    @test isempty(Corset.Engine.diagnostics([possible], definite_only))
    warned = Report([Diagnostic(possible, Level.warn, "test")], definite_only, @__DIR__, Dict{String, String}(), 0, [])
    @test !Corset.Engine.failed(warned)
    strict = Config.settings(nothing, Flags(; deny_warnings = true), REGISTRY)
    @test Corset.Engine.failed(Report(warned.diagnostics, strict, @__DIR__, Dict{String, String}(), 0, []))
end

@testset "opt-outs" begin
    report = Corset.check(joinpath(@__DIR__, "optout", "cases.jl"))
    lines = Dict(path => Corset.Render.line_starts(text) for (path, text) in report.sources)
    located = [
        (diagnostic.finding.rule, diagnostic.finding.kind, searchsortedlast(lines[diagnostic.finding.primary.span.file], diagnostic.finding.primary.span.first_byte))
            for diagnostic in report.diagnostics
    ]
    optout = Symbol("opt-out")
    @test located == [
        (Symbol("approx-zero"), :literal_zero, 10), (optout, :unused, 11), (optout, :no_reason, 12), (optout, :unknown_rule, 13),
        (optout, :malformed, 14), (optout, :late_file, 15),
    ]
    @test all(diagnostic.level == Level.deny for diagnostic in report.diagnostics)
    @test occursin("= note: deny from opt-out check, always on", sprint(io -> Corset.Render.render_all(io, report)))
    file = Corset.Syntax.parse_file("end.jl", "x = 1\n# corset: allow one-letter -- nothing follows\n")
    kept, problems = Corset.OptOuts.apply(Facts.FactSet([file]), Finding[], Set([Symbol("one-letter")]))
    @test isempty(kept) && [problem.kind for problem in problems] == [:unused]
end

@testset "baseline" begin
    nested = Corset.Syntax.parse_file("d.jl", "module M\nstruct S{T} <: A\n    x::T\nend\nf(x::T)::T where {T} = x\nend\n")
    @test Corset.Baseline.definition_name(nested, first(findfirst("x::T\nend", nested.text))) == "S"
    @test Corset.Baseline.definition_name(nested, last(findfirst("= x", nested.text))) == "f"
    @test Corset.Baseline.definition_name(nested, 1) == "M"
    @test Corset.Baseline.definition_name(Corset.Syntax.parse_file("t.jl", "x = 1\n"), 1) == ""
    directory = mktempdir(@__DIR__)
    write(joinpath(directory, "Project.toml"), "[deps]\n")
    source = "near(value) = value ≈ 0\nfunction far(value)\n    return value ≈ 0\nend\n"
    write(joinpath(directory, "a.jl"), source)
    @test Corset.Engine.baseline(directory) == 2
    clean = Corset.check(directory)
    @test isempty(clean.diagnostics) && clean.baselined == 2 && isempty(clean.stale) && !Corset.Engine.failed(clean)
    write(joinpath(directory, "a.jl"), "# moved down\n\n" * source * "extra(value) = value ≈ 0\n")
    moved = Corset.check(directory)
    @test moved.baselined == 2
    @test [Corset.Baseline.key(Corset.Syntax.parse_file(joinpath(directory, "a.jl"), read(joinpath(directory, "a.jl"), String)), directory, d.finding).definition for d in moved.diagnostics] == ["extra"]
    write(joinpath(directory, "a.jl"), "near(value) = value ≈ 0\n")
    fixed = Corset.check(directory)
    @test fixed.baselined == 1 && [key.definition for key in fixed.stale] == ["far"] && Corset.Engine.failed(fixed)
    @test occursin("error[baseline]: 1 baseline entry matches no finding", sprint(io -> Corset.Render.render_all(io, fixed)))
    write(joinpath(directory, Corset.Baseline.FILE), "[[finding]]\nrule = 1\n")
    @test_throws ConfigError Corset.check(directory)
    write(joinpath(directory, Corset.Baseline.FILE), "[[finding]]\nrule = 1\nfile = \"a.jl\"\ndefinition = \"\"\nsnippet = \"s\"\ncount = 1\n")
    @test_throws ConfigError Corset.check(directory)
    rm(directory; recursive = true)
end
