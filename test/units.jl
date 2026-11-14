# Unit tests for skeleton pieces that UI snapshots do not reach.

using Corset: Corset
using Corset.Facts: Facts, Span, Label, Edit, Fix, Finding, Precision, Tier, Confidence, Group, Role, IndexedPattern, @pattern
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
    @test Corset.Fixes.apply_edits(text, [edit(1, 4, ""), edit(1, 0, "new ")]) == "new def"
    findings = [
        sample_finding(1:1; fix = Fix("t", [edit(1, 1, "A")], Tier.safe)),
        sample_finding(5:7; fix = Fix("t", [edit(5, 7, "xyz")], Tier.breaking)),
        sample_finding(2:2; fix = Fix("t", Edit[], Tier.manual)),
        sample_finding(3:3),
    ]
    @test length(Corset.Fixes.applicable_edits(findings, Tier.safe)) == 1
    @test length(Corset.Fixes.applicable_edits(findings, Tier.manual)) == 2
    @test_throws ArgumentError Corset.Fixes.apply_edits(text, [edit(1, 1, "A"), Edit(Span("g.jl", 5, 7, Precision.exact), "y")])
    # Fix spanning two files applies whole or not at all; overlap in either file skips it.
    moved(bytes) = Fix("t", [edit(bytes, bytes, ""), Edit(Span("g.jl", 1, 0, Precision.exact), "x")], Tier.safe)
    @test Corset.Fixes.applicable_edits([sample_finding(1:1; fix = moved(1)), sample_finding(1:1; fix = moved(1))], Tier.safe) == moved(1).edits
    @test length(Corset.Fixes.applicable_edits([sample_finding(1:1; fix = moved(1)), sample_finding(3:3; fix = moved(3))], Tier.safe)) == 4
end

@testset "explicit import with use outside analyzed files gives no fact" begin
    root = joinpath(@__DIR__, "ui", "misplaced-import", "positive", "src")
    main = joinpath(root, "MisplacedImportPositive.jl")
    analysis = Corset.External.ExplicitImports.get_names_used(main)
    parsed(path) = Corset.Syntax.parse_file(path, read(path, String), Role.package)
    # `import Dates` in module file has its only use in `clock.jl`; without it, import would look unused.
    imports(files) = Corset.External.explicit_imports(analysis, files, Corset.External.global_uses(analysis))
    dates(files) = filter(imported -> imported.names == [:Dates], imports(files))
    @test length(dates([parsed(main), parsed(joinpath(root, "clock.jl"))])) == 1
    @test isempty(dates([parsed(main)]))
end

@testset "render" begin
    text = "a = 1\nb = 2\nc = 3\nd = 4\ne = 5\n"
    sources = Dict("f.jl" => text, "g.jl" => "x = 1\ny = 2\n")
    render(finding) = sprint(io -> Corset.Render.render(io, Diagnostic(finding, Level.warn, "test"), sources, ".", false))
    adjacent = render(sample_finding(13:17; causes = [Label(Span("f.jl", 1, 5, Precision.exact), "cause")]))
    @test occursin("2 | b = 2", adjacent)
    gap = render(sample_finding(25:29; causes = [Label(Span("f.jl", 1, 5, Precision.exact), "cause")]))
    @test occursin("...", gap)
    whole_line = render(sample_finding(15:15; precision = Precision.line))
    @test occursin("  | ^^^^^ primary", whole_line)
    multi_line = render(sample_finding(1:9))
    @test occursin("  | ^^^^^ primary", multi_line)
    # Cause in other file gets own snippet, with its own lines; once drew on primary file text.
    elsewhere = render(sample_finding(13:17; causes = [Label(Span("g.jl", 7, 7, Precision.exact), "there"), Label(Span("f.jl", 1, 1, Precision.exact), "here")]))
    @test occursin(" --> f.jl:3:1\n  |\n1 | a = 1\n  | - here\n2 | b = 2\n3 | c = 3\n  | ^^^^^ primary\n  |\n ::: g.jl:2:1\n  |\n2 | y = 2\n  | - there\n  |\n  = why", elsewhere)
    @test Corset.Render.line_text("x\r\n", [1, 4], 1) == "x"
    tabbed = "\ty = 1\n"
    @test occursin("1 |     y = 1\n  |     ^ primary", sprint(io -> Corset.Render.render(io, Diagnostic(sample_finding(2:2), Level.warn, "test"), Dict("f.jl" => tabbed), ".", false)))
end

@testset "facts" begin
    @test isnothing(IndexedPattern(@pattern {x}).roots)
    @test isnothing(IndexedPattern(@pattern ~or(f({x}), {y})).roots)
    mixed = IndexedPattern(@pattern ~or(f({x}), g({x}), [], {a}.b({x}), h({x})))
    @test mixed.roots[Corset.Syntax.JS.K"call"] === nothing
    @test mixed.roots[Corset.Syntax.JS.K"vect"] === nothing
    @test IndexedPattern(@pattern ~or(f({x}), g({x}))).roots[Corset.Syntax.JS.K"call"] == Set(["f", "g"])
    file = Corset.Syntax.parse_file("f.jl", "g(1)\n", Role.package)
    @test length(Facts.matches(file, IndexedPattern(@pattern {x}))) > 1
    @test Facts.identifier_name(only(Facts.leaves(file, "Integer"))) === nothing
    @test isempty(Facts.children_of(only(Facts.leaves(file, "Integer"))))
    text = "a = :(b = 1)\nc = :(f(\$(d = 2)))\n@dsl {e} = 3\n@test (g = 4)\nquote quote \$(h = 5) end end\n"
    quoted = Corset.Syntax.parse_file("q.jl", text, Role.package)
    @test [Facts.source(quoted, node) for node in Facts.forms(quoted, "=")] == ["a = :(b = 1)", "c = :(f(\$(d = 2)))", "(d = 2)", "(g = 4)"]
    # Grouping parentheses belong to parent in JuliaSyntax tree; source keeps them, span does not.
    grouped = Corset.Syntax.parse_file("g.jl", "f((x), y, (( a + b )), (c, d), (p)(q))\n", Role.package)
    call = first(Facts.forms(grouped, "call"))
    @test [Facts.source(grouped, node) for node in Facts.children_of(call)] == ["f", "(x)", "y", "(( a + b ))", "(c, d)", "(p)(q)"]
    @test [Facts.source(grouped, node) for node in Facts.children_of(Facts.children_of(call)[6])] == ["(p)", "q"]
    @test Facts.span(grouped, Facts.children_of(call)[2]).first_byte == 4
    # Parse error leaves empty parentheses: they group nothing.
    @test isempty(Corset.Syntax.parse_file("e.jl", "x = (end)\n", Role.package).groups)
    # Children are shared with tree: mutation must fail loud.
    @test_throws MethodError push!(Facts.children_of(call), call)
    # String macro name has no `@`; at file start, byte before it does not exist.
    macros = Corset.Syntax.parse_file("m.jl", "raw\"x\"\n@async f()\nThreads.@async f()\n@. x + 1\n", Role.package)
    @test [Facts.macro_name(macros, node) for node in Facts.forms(macros, "macrocall")] == ["raw", "@async", "Threads.@async", "@."]
    # Base macro reads module path as written; macro of other module and other nodes give `nothing`.
    calls = Corset.Syntax.parse_file("c.jl", "@spawn f()\nBase.Threads.@spawn f()\n@Threads.spawn f()\nMine.@spawn f()\n", Role.package)
    @test [Facts.base_macro(node) for node in Facts.forms(calls, "macrocall")] == ["@spawn", "@spawn", "@spawn", nothing]
    @test isnothing(Facts.base_macro(only(Facts.forms(calls, "toplevel"))))
    # Call head reads Base module path as written; function of other module gives `nothing`.
    heads = Corset.Syntax.parse_file("h.jl", "error(1)\nBase.include(@__MODULE__, \"c.jl\")\nCore.Task(f)\nMine.error(1)\na == b\n", Role.package)
    @test [Facts.call_head(node) for node in Facts.forms(heads, "call")] == ["error", "include", "Task", nothing, "=="]
    @test length(Facts.include_calls(heads)) == 1
    # Version tests settle on running Julia and every later release; platform tests and future bounds stay open.
    conditions = [
        "isdefined(Base, :get_extension)" => true, "!isdefined(Core, :get_extension)" => nothing, "isdefined(Base, :no_such_name)" => nothing,
        "isdefined(Base, :(a.b))" => nothing, "isdefined(Mine, :x)" => nothing, "!isdefined(Base, :get_extension)" => false,
        "VERSION >= v\"1.9\"" => true, "v\"1.9\" <= VERSION" => true, "VERSION < v\"1.9\"" => false, "VERSION < v\"99\"" => nothing,
        "VERSION >= v\"99\"" => nothing, "VERSION < x" => nothing, "a < b" => nothing, "VERSION == v\"1.9\"" => nothing,
        "Sys.iswindows()" => nothing, "VERSION < v\"1.9\" && Sys.iswindows()" => false, "VERSION >= v\"1.9\" || x" => true,
        "VERSION > v\"1.0\" && isdefined(Base, :get_extension)" => true, "VERSION <= v\"1.0\" || VERSION < v\"1.9\"" => false,
        "x && y" => nothing, "!x" => nothing,
    ]
    for (text, expected) in conditions
        @test Facts.settled(Facts.children_of(Corset.Syntax.parse_file("v.jl", text * "\n", Role.package).tree)[1]) === expected
    end
    branches = Corset.Syntax.parse_file(
        "i.jl", """
        if VERSION < v"1.9"
            include("old.jl")
        elseif VERSION >= v"1.9"
            include("new.jl")
        else
            include("old.jl")
        end
        if Sys.iswindows()
            include("windows.jl")
        end
        """, Role.package,
    )
    @test [Facts.source(branches, call) for call in Facts.include_calls(branches)] == ["include(\"new.jl\")", "include(\"windows.jl\")"]
    # Binding sites: destructured names bind; anonymous `::T` binds nothing.
    bound = Corset.Syntax.parse_file("b.jl", "f(::Int, (a, b), c::Int = 1; d = 2, e...) = 1\ntmp, (other, x...) = pair\nfor (i, item) in pairs end\n(; k, l) = nt\nv[1] = 2\n", Role.package)
    @test [Facts.identifier_name(site.name) for site in bound.bindings] == ["a", "b", "c", "d", "e", "tmp", "other", "x", "k", "l", "i", "item", "f"]
    # Normalized source: layout run becomes one space; comments drop; string contents and significant spaces stay.
    shapes = Corset.Syntax.parse_file("n.jl", "a = [1 -2]\nb = [1 - 2]\nc = x == \"a  b\" #= c =#  &&  y\n", Role.package)
    @test [Facts.normalized_source(shapes, node) for node in Facts.forms(shapes, "=")] == ["a = [1 -2]", "b = [1 - 2]", "c = x == \"a  b\" && y"]
end

@testset "engine" begin
    mktempdir(@__DIR__) do directory
        write(joinpath(directory, "a.jl"), "x ≈ 0\n")
        write(joinpath(directory, "notes.txt"), "x ≈ 0\n")
        report = Corset.check(directory)
        @test [diagnostic.finding.rule for diagnostic in report.diagnostics] == [Symbol("approx-zero")]
        @test report.settings.kind == Kind.application
        @test Corset.Engine.failed(report)
        @test_throws ArgumentError Corset.Rules.entry(:no_such_check)
    end
end

"""Paths, relative to `root`, of files `Discovery.discover` picks for `path`."""
discovered(root::String, path::String = root)::Vector{String} = [relpath(file.path, root) for file in Corset.Discovery.discover(path).files]

"""Flags that allow every rule after `syntax` stage, so run loads no package: discovery fixtures are not loadable."""
const SYNTAX_ONLY = Corset.Config.Flags(;
    levels = [string(entry.name) => Corset.Config.Level.allow for entry in Corset.Rules.REGISTRY if entry.stage != Corset.Facts.Stage.syntax],
)

@testset "defined name" begin
    # Parenthesized operator once lost exact method site: `(==)` never matched method name `==`.
    text = "Base.:(==)(a, b) = true\nBase.:+(a, b) = a\nfunction Base.show(io, x) end\n(!=)(a, b) = false\nlocal_name(x) = x\n"
    file = Corset.Syntax.parse_file("names.jl", text, Role.package)
    @test [Corset.Package.defined_name(file, node) for node in Corset.Facts.forms(file, "function")] == ["==", "+", "show", "!=", "local_name"]
end

@testset "discovery" begin
    mktempdir(@__DIR__) do root
        files = Dict(
            "Project.toml" => "name = \"Pkg\"\n\n[weakdeps]\nA = \"$(Base.UUID(rand(UInt128)))\"\nB = \"$(Base.UUID(rand(UInt128)))\"\n\n[extensions]\nFlatExt = \"A\"\nNestedExt = \"B\"\n\n[preferences.Corset]\nkind = \"library\"\n",
            "src/Pkg.jl" => "module Pkg\ninclude(\"a.jl\")\ninclude(joinpath(@__DIR__, \"sub\", \"b.jl\"))\ninclude(name)\ninclude(\"gone.jl\")\nend\n",
            "src/a.jl" => "include(\"a.jl\")\n",
            "src/sub/b.jl" => "x = 1\n",
            "src/orphan.jl" => "y = 2\n",
            "ext/FlatExt.jl" => "module FlatExt end\n",
            "ext/NestedExt/NestedExt.jl" => "module NestedExt end\n",
            "test/runtests.jl" => "include(\"cases.jl\")\n",
            "test/cases.jl" => "z = 3\n",
            "test/fixtures/bad.jl" => "x ≈ 0\n",
            ".hidden/c.jl" => "w = 4\n",
            "lib/Other/Project.toml" => "",
            "lib/Other/d.jl" => "v = 5\n",
            "scripts/e.jl" => "u = 6\n",
        )
        for (path, text) in files
            mkpath(dirname(joinpath(root, path)))
            write(joinpath(root, path), text)
        end
        @test discovered(root) == [
            "src/Pkg.jl", "ext/FlatExt.jl", "ext/NestedExt/NestedExt.jl", "test/runtests.jl", "src/a.jl", "src/sub/b.jl", "test/cases.jl",
        ]
        roles = [(relpath(file.path, root), file.role) for file in Corset.Discovery.discover(root).files]
        @test sort!([path for (path, role) in roles if role == Role.package]) == ["ext/FlatExt.jl", "ext/NestedExt/NestedExt.jl", "src/Pkg.jl", "src/a.jl", "src/sub/b.jl"]
        @test only(Corset.Discovery.discover(joinpath(root, "lib", "Other")).files).role == Role.script
        @test [spot.cause for spot in Corset.Discovery.discover(root).blind_spots] == ["include with computed path", "include of missing file"]
        @test discovered(root, joinpath(root, "src", "a.jl")) == ["src/a.jl"]
        @test [relpath(entry, root) for entry in Corset.Discovery.discover(root).entries] == ["src/Pkg.jl", "ext/FlatExt.jl", "ext/NestedExt/NestedExt.jl", "test/runtests.jl"]
        @test Corset.Discovery.discover(joinpath(root, "src", "a.jl")).entries == [joinpath(root, "src", "a.jl")]
        @test isempty(Corset.Discovery.discover(joinpath(root, "scripts")).entries)
        @test sprint(Corset.Render.render_coverage, Corset.check(root; flags = SYNTAX_ONLY)) == """
            coverage: analyzed 7 files; skipped 2 (1 include of missing file, 1 include with computed path)
              - src/Pkg.jl:4:1: include with computed path
              - src/Pkg.jl:5:1: include of missing file
            """
        rm(joinpath(root, "Project.toml"))
        @test all(file -> file.role == Role.script, Corset.Discovery.discover(root).files)
        @test discovered(root) == ["ext/FlatExt.jl", "ext/NestedExt/NestedExt.jl", "scripts/e.jl", "src/Pkg.jl", "src/a.jl", "src/orphan.jl", "src/sub/b.jl", "test/cases.jl", "test/fixtures/bad.jl", "test/runtests.jl"]
        write(joinpath(root, "Project.toml"), "name = \"Missing\"\n")
        @test_throws Corset.Config.ConfigError Corset.Discovery.discover(root)
        # Broken Project.toml stops every run inside project, as in Cargo.
        write(joinpath(root, "Project.toml"), "name = \"Pkg\"\n\n[weakdeps]\nC = \"$(Base.UUID(rand(UInt128)))\"\n\n[extensions]\nGoneExt = \"C\"\n\n[preferences.Corset]\nkind = \"library\"\n")
        @test_throws "extension GoneExt has no file ext/GoneExt.jl" Corset.Discovery.discover(root)
        @test_throws "extension GoneExt has no file ext/GoneExt.jl" Corset.check(joinpath(root, "src"); flags = SYNTAX_ONLY)
    end
end

@testset "pipeline runs on legacy sources" begin
    # Real code finds crashes that fixtures miss; replace this corpus once legacy code is deleted.
    mktempdir(@__DIR__) do directory
        cp(joinpath(dirname(@__DIR__), "lib", "CorsetLegacy", "src"), joinpath(directory, "src"))
        write(joinpath(directory, "Project.toml"), "name = \"CorsetLegacy\"\n\n[preferences.Corset]\nkind = \"library\"\n")
        # Copy lacks legacy dependencies, so it cannot load; corpus tests syntax stage.
        report = Corset.check(directory; flags = SYNTAX_ONLY)
        @test !isempty(report.diagnostics)
        @test length(report.sources) == count(endswith(".jl"), [name for (_, _, names) in walkdir(joinpath(directory, "src")) for name in names])
        # `configured_signatures` loads user file with `Base.include(holder, path)`: path is computed.
        @test [spot.cause for spot in report.blind_spots] == ["include with computed path"]
        @test isnothing(Corset.Render.render_all(devnull, report))
        @test length(Corset.Output.json_report(report)["diagnostics"]) == length(report.diagnostics)
        @test length(only(Corset.Output.sarif_report(report, "0")["runs"])["results"]) == length(report.diagnostics)
    end
end

const CONFIG = joinpath(@__DIR__, "config")
# Package stage loads `library` fixture in place, so test environment must load it from its root.
joinpath(CONFIG, "library") in LOAD_PATH || push!(LOAD_PATH, joinpath(CONFIG, "library"))

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
    for broken in ("missing-kind", "bad-level", "unknown-rule", "unknown-key", "broken-toml", "not-table")
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
    # Ban entry: one of `pattern` and `name`, reason with text, valid pattern or regex. Name regex matches whole name.
    @test Config.ban(Config.BanTable(; name = "tmp.*", reason = "r")).target == r"^(?:tmp.*)$"
    @test Config.ban(Config.BanTable(; pattern = "eval", reason = "r")).text == "eval"
    for (pattern, name, reason) in (
            (nothing, nothing, "r"), ("f()", "x", "r"), (nothing, "x", " "), ("f(", nothing, "r"), ("a b", nothing, "r"), ("", nothing, "r"), ("@esc(x, :some)", nothing, "r"), (nothing, "(", "r"), (nothing, "a)|(b", "r"),
        )
        @test_throws ConfigError Config.ban(Config.BanTable(; pattern, name, reason))
    end
    project, local_bans = Config.Table(; banned = [Config.BanTable(; name = "a", reason = "r")]), Config.Table(; banned = Config.BanTable[])
    @test isempty(Config.overlay(project, local_bans).banned) && length(Config.overlay(project, Config.Table()).banned) == 1
    mktempdir(@__DIR__) do directory
        write(joinpath(directory, "LocalPreferences.toml"), "[Corset]\nbanned = [{ name = \"x\", reason = \"r\", group = \"correctness\" }]\n")
        @test_throws ConfigError Config.read_table(joinpath(directory, "LocalPreferences.toml"), ("Corset",))
        # Missing key means defaults; key holding other value than table is error.
        project_file = joinpath(directory, "Project.toml")
        write(project_file, "name = \"P\"\n")
        @test Config.read_table(project_file, ("preferences", "Corset")) == Config.Table()
        for text in ("preferences = 1\n", "[preferences]\nCorset = \"library\"\n")
            write(project_file, text)
            @test_throws ConfigError Config.read_table(project_file, ("preferences", "Corset"))
        end
    end
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
    warned = Report([Diagnostic(possible, Level.warn, "test")], definite_only, @__DIR__, Dict{String, String}(), 0, [], [])
    @test !Corset.Engine.failed(warned)
    strict = Config.settings(nothing, Flags(; deny_warnings = true), REGISTRY)
    @test Corset.Engine.failed(Report(warned.diagnostics, strict, @__DIR__, Dict{String, String}(), 0, [], []))
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
    file = Corset.Syntax.parse_file("end.jl", "x = 1\n# corset: allow one-letter -- nothing follows\n", Role.package)
    kept, problems = Corset.OptOuts.apply(Facts.FactSet([file], String[], Facts.Ban[], nothing, nothing, nothing), Finding[], Set([Symbol("one-letter")]))
    @test isempty(kept) && [problem.kind for problem in problems] == [:unused]
end

@testset "baseline" begin
    nested = Corset.Syntax.parse_file("d.jl", "module M\nstruct S{T} <: A\n    x::T\nend\nf(x::T)::T where {T} = x\nend\n", Role.package)
    @test Corset.Baseline.definition_name(Corset.Baseline.Definitions(nested), first(findfirst("x::T\nend", nested.text))) == "S"
    @test Corset.Baseline.definition_name(Corset.Baseline.Definitions(nested), last(findfirst("= x", nested.text))) == "f"
    @test Corset.Baseline.definition_name(Corset.Baseline.Definitions(nested), 1) == "M"
    @test Corset.Baseline.definition_name(Corset.Baseline.Definitions(Corset.Syntax.parse_file("t.jl", "x = 1\n", Role.package)), 1) == ""
    mktempdir(@__DIR__) do directory
        write(joinpath(directory, "Project.toml"), "[deps]\n")
        source = "near(value::Real)::Bool = value ≈ 0\nfunction far(value::Real)::Bool\n    return value ≈ 0\nend\n"
        write(joinpath(directory, "a.jl"), source)
        @test Corset.Engine.baseline(directory) == 2
        clean = Corset.check(directory)
        @test isempty(clean.diagnostics) && clean.baselined == 2 && isempty(clean.stale) && !Corset.Engine.failed(clean)
        write(joinpath(directory, "a.jl"), "# moved down\n\n" * source * "extra(value::Real)::Bool = value ≈ 0\n")
        moved = Corset.check(directory)
        @test moved.baselined == 2
        definitions = Corset.Baseline.Definitions(Corset.Syntax.parse_file(joinpath(directory, "a.jl"), read(joinpath(directory, "a.jl"), String), Role.script))
        @test [Corset.Baseline.key(definitions, directory, d.finding).definition for d in moved.diagnostics] == ["extra"]
        write(joinpath(directory, "a.jl"), "near(value::Real)::Bool = value ≈ 0\n")
        fixed = Corset.check(directory)
        @test fixed.baselined == 1 && [key.definition for key in fixed.stale] == ["far"] && Corset.Engine.failed(fixed)
        @test occursin("error[baseline]: 1 baseline entry matches no finding", sprint(io -> Corset.Render.render_all(io, fixed)))
        write(joinpath(directory, Corset.Baseline.FILE), "[[finding]]\nrule = 1\n")
        @test_throws ConfigError Corset.check(directory)
        write(joinpath(directory, Corset.Baseline.FILE), "[[finding]]\nrule = 1\nfile = \"a.jl\"\ndefinition = \"\"\nsnippet = \"s\"\ncount = 1\n")
        @test_throws ConfigError Corset.check(directory)
    end
end
