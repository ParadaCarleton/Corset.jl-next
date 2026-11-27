# Unit tests for skeleton pieces that UI snapshots do not reach.

using Corset: Corset
using Corset.Facts: Facts, Span, Label, Edit, Fix, Finding, Precision, Tier, Confidence, Group, Role, IndexedPattern, @pattern, BlindSpot
using Corset.Config: Config, ConfigError, Flags, Kind, Level, Settings
using Corset.Engine: Diagnostic, Report
using Corset.Rules: REGISTRY, entry
using EvilArrays: EvilArray
using Test: @test, @testset, @test_throws

include("helpers.jl")

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
    # Check after fix keeps every option but `--tier`, which `check` rejects.
    @test Corset.CLI.recheck_arguments(["fix", "src", "--tier", "safe", "-A", "x"]) == ["check", "src", "-A", "x"]
    @test Corset.CLI.recheck_arguments(["fix", "--tier=likely", "src"]) == ["check", "src"]
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
    # Equal insertion of two fixes (same import) applies once.
    @test Corset.Fixes.applicable_edits([sample_finding(1:1; fix = moved(1)), sample_finding(3:3; fix = moved(3))], Tier.safe) == [moved(1).edits; edit(3, 3, "")]
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

@testset "bare using outside analyzed files gives no statement" begin
    case = joinpath(@__DIR__, "ui", "implicit-import", "positive")
    main = joinpath(case, "src", "ImplicitImportPositive.jl")
    push!(LOAD_PATH, case)
    mod = try
        Base.require(Base.PkgId(Base.UUID("ec46480a-c2ea-4146-87ea-013ef373755c"), "ImplicitImportPositive"))
    finally
        pop!(LOAD_PATH)
    end
    analysis = Corset.External.ExplicitImports.get_names_used(main)
    files(paths::String...) = Dict(path => Corset.Syntax.parse_file(path, read(path, String), Role.package) for path in paths)
    statement(paths::String...) = Corset.External.bare_statement(mod, mod.LinearAlgebra, analysis, files(paths...))
    @test first(statement(main)).path == main
    @test isnothing(statement(joinpath(case, "src", "geometry.jl")))
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

@testset "widened arguments take offset vectors" begin
    key, other = (Corset.Baseline.Key("rule", "f.jl", "f", snippet) for snippet in ("a", "b"))
    @test Corset.Baseline.cover(Dict(key => 1), EvilArray([key, other])) == ([true, false], Corset.Baseline.Key[])
    @test Corset.Rules.Docstring.as_docstring("# note\n", EvilArray([1:6]), "") == "\"\"\"note\"\"\""
    @test_throws ArgumentError Corset.Render.line_text("a\nb", EvilArray([1, 3]), 1)
    instance = Base.method_instance(first, (Vector{Int},))
    site = Facts.MethodSite(instance.def, Corset.Syntax.parse_file("f.jl", "f(x) = x\n", Role.package), nothing, Span("f.jl", 1, 1, Precision.line))
    nodes = Union{Nothing, Facts.SyntaxNode}[nothing]
    @test_throws ArgumentError Corset.Inference.spans(only(code_lowered(first, (Vector{Int},))), instance, site, EvilArray([1, 4]), nodes)
end

@testset "swapped types keep element types of caller" begin
    @test Corset.Widening.with_swaps([Int, Float64], Dict(1 => Float32), (1,)) == Any[Float32, Float64]
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
    # Discarded value: branch, chain tail, `let` and `begin` body follow their construct; conditions and results stay used.
    flow = Corset.Syntax.parse_file(
        "d.jl", """
        for t in ts
            ready(t) && @async run(t)
            if a
                b ? c() : d()
            elseif e
                let g = 1
                    begin
                        h()
                    end
                end
            end
        end
        f(x) = x > 0 || k()
        y = p ? q() : r()
        if s() || u()
            v()
        end
        w = let
            m()
        end
        """, Role.package,
    )
    gone = [Facts.source(flow, node) for kind in ("call", "macrocall") for node in Facts.forms(flow, kind) if Facts.discarded(node)]
    @test sort(gone) == ["@async run(t)", "c()", "d()", "h()", "v()"]
    # File value: `include` returns last top-level statement, also from inside `begin`.
    tail = Corset.Syntax.parse_file("t.jl", "f() || g()\nbegin\n    h()\nend\n", Role.package)
    @test [Facts.source(tail, node) => Facts.discarded(node) for node in Facts.forms(tail, "call")] == ["f()" => false, "g()" => true, "h()" => false]
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
discovered(root::String, path::String = root)::Vector{String} = [relpath(file.path, root) for file in Corset.Discovery.discover(path; environment = nothing).files]

"""Flags that allow every rule after `syntax` stage, so run loads no package: discovery fixtures are not loadable."""
const SYNTAX_ONLY = Corset.Config.Flags(;
    levels = [string(entry.name) => Corset.Config.Level.allow for entry in Corset.Rules.REGISTRY if entry.fix_stage != Corset.Facts.Stage.syntax],
)

@testset "fix stage" begin
    @test_throws ArgumentError Facts.RuleEntry(:early, Group.readability, Int[], Facts.Stage.inference, Facts.Stage.syntax, identity)
    # Registry builds entries at precompile time, where coverage cannot see them.
    @test Facts.RuleEntry(:same, Group.readability, Int[], Facts.Stage.syntax, identity).fix_stage == Facts.Stage.syntax
    @test Facts.RuleEntry(:later, Group.readability, Int[], Facts.Stage.syntax, Facts.Stage.inference, identity).fix_stage == Facts.Stage.inference
    # `annotation` alone needs inference facts for its fix, though its findings read syntax only.
    alone = Dict{String, Tuple{Level.T, String}}(string(rule.name) => (Level.allow, "test") for rule in REGISTRY if rule.name != :annotation)
    settings = Settings(Kind.library, Confidence.definite, Tier.likely, alone, false, Facts.Ban[])
    @test Corset.Engine.wants(settings, Facts.Stage.inference)
    @test Corset.Engine.needs_package(settings)
    none = Settings(Kind.library, Confidence.definite, Tier.likely, merge(alone, Dict("annotation" => (Level.allow, "test"))), false, Facts.Ban[])
    @test !Corset.Engine.wants(none, Facts.Stage.inference)
    @test !Corset.Engine.needs_package(none)
end

@testset "defined name" begin
    # Parenthesized operator once lost exact method site: `(==)` never matched method name `==`.
    text = "Base.:(==)(a, b) = true\nBase.:+(a, b) = a\nfunction Base.show(io, x) end\n(!=)(a, b) = false\nlocal_name(x) = x\n"
    # Infix definition once named its first argument; callable object method named its instance.
    text *= "left ⊕ right = left\n(s::S)(x) = x\n(::S{T})(x) where {T} = x\n"
    file = Corset.Syntax.parse_file("names.jl", text, Role.package)
    definitions = Corset.Facts.forms(file, "function")
    @test [Corset.Package.defined_name(file, node) for node in definitions] == ["==", "+", "show", "!=", "local_name", "⊕", "S", "S"]
    @test [Facts.source(file, node) for node in Facts.signature(definitions[6]).arguments] == ["left", "right"]
    # Infix operator is no parameter; callable object binds instance and defines no name.
    bound = Corset.Syntax.parse_file("bound.jl", "left ⊕ right = left\n(s::S)(x) = x\n", Role.package)
    @test [(Facts.source(bound, site.name), site.kind) for site in bound.bindings] == [
        ("left", Facts.BindingKind.parameter), ("right", Facts.BindingKind.parameter), ("s", Facts.BindingKind.parameter),
        ("x", Facts.BindingKind.parameter), ("⊕", Facts.BindingKind.definition),
    ]
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
        roles = [(relpath(file.path, root), file.role) for file in Corset.Discovery.discover(root; environment = nothing).files]
        @test sort!([path for (path, role) in roles if role == Role.package]) == ["ext/FlatExt.jl", "ext/NestedExt/NestedExt.jl", "src/Pkg.jl", "src/a.jl", "src/sub/b.jl"]
        @test only(Corset.Discovery.discover(joinpath(root, "lib", "Other"); environment = nothing).files).role == Role.script
        @test [spot.cause for spot in Corset.Discovery.discover(root; environment = nothing).blind_spots] == ["include with computed path", "include of missing file"]
        @test discovered(root, joinpath(root, "src", "a.jl")) == ["src/a.jl"]
        @test [relpath(entry, root) for entry in Corset.Discovery.discover(root; environment = nothing).entries] == ["src/Pkg.jl", "ext/FlatExt.jl", "ext/NestedExt/NestedExt.jl", "test/runtests.jl"]
        @test Corset.Discovery.discover(joinpath(root, "src", "a.jl"); environment = nothing).entries == [joinpath(root, "src", "a.jl")]
        @test isempty(Corset.Discovery.discover(joinpath(root, "scripts"); environment = nothing).entries)
        @test sprint(Corset.Render.render_coverage, Corset.check(root; flags = SYNTAX_ONLY)) == """
            coverage: analyzed 7 files; skipped 2 (include of missing file: 1, include with computed path: 1)
              - src/Pkg.jl:5:1: include of missing file
              - src/Pkg.jl:4:1: include with computed path
            """
        rm(joinpath(root, "Project.toml"))
        @test all(file -> file.role == Role.script, Corset.Discovery.discover(root; environment = nothing).files)
        @test discovered(root) == ["ext/FlatExt.jl", "ext/NestedExt/NestedExt.jl", "scripts/e.jl", "src/Pkg.jl", "src/a.jl", "src/orphan.jl", "src/sub/b.jl", "test/cases.jl", "test/fixtures/bad.jl", "test/runtests.jl"]
        write(joinpath(root, "Project.toml"), "name = \"Missing\"\n")
        @test_throws Corset.Config.ConfigError Corset.Discovery.discover(root; environment = nothing)
        # Broken Project.toml stops every run inside project, as in Cargo.
        write(joinpath(root, "Project.toml"), "name = \"Pkg\"\n\n[weakdeps]\nC = \"$(Base.UUID(rand(UInt128)))\"\n\n[extensions]\nGoneExt = \"C\"\n\n[preferences.Corset]\nkind = \"library\"\n")
        @test_throws "extension GoneExt has no file ext/GoneExt.jl" Corset.Discovery.discover(root; environment = nothing)
        @test_throws "extension GoneExt has no file ext/GoneExt.jl" Corset.check(joinpath(root, "src"); flags = SYNTAX_ONLY)
        write(joinpath(root, "Project.toml"), "name = \"Pkg\"\n\n[weakdeps]\nA = \"$(Base.UUID(rand(UInt128)))\"\nB = \"$(Base.UUID(rand(UInt128)))\"\n\n[extensions]\nFlatExt = [\"A\", \"B\"]\n")
        @test [id.name for id in only(Corset.Discovery.project_facts(root; environment = nothing).extensions).triggers] == ["A", "B"]
        # TOML parses empty list as `Vector{Any}`; extension without trigger never loads.
        write(joinpath(root, "Project.toml"), "name = \"Pkg\"\n\n[extensions]\nFlatExt = []\n")
        @test_throws "extension FlatExt needs trigger name or list of names" Corset.Discovery.discover(root; environment = nothing)
    end
end

"""
Entry of package `name` with computed includes: loop, branch, function body and macro argument, which load can skip;
file beside package root, outside project, which load always includes; quoted include, which is data.
"""
loop_entry(name::String)::String = """
module $name
for part in ("a", "b")
    include("\$part.jl")
end
if get(ENV, "CORSET_EXTRA", "0") == "1"
    include(string("c", ".jl"))
end
load_c() = include(string("c", ".jl"))
include(joinpath(dirname(dirname(@__DIR__)), string("shared", ".jl")))
const later = :(include(string("c", ".jl")))
@eval include(string("c", ".jl"))
end
"""

@testset "computed includes resolve from precompile cache" begin
    # `a.jl` includes `e.jl` only when called: cache omits it, discovery follows it.
    parts = ["src/a.jl" => "load_e() = include(\"e.jl\")\n", "src/b.jl" => "b = 1\n", "src/c.jl" => "c = 1\n", "src/e.jl" => "e = 1\n"]
    extension = "ext/LoopsExt.jl" => "module LoopsExt\nusing Random: Random\ninclude(string(\"x\", \".jl\"))\nend\n"
    mktempdir(@__DIR__) do parent
        write(joinpath(parent, "shared.jl"), "shared = 1\n")
        with_package(parent, "Loops", "src/Loops.jl" => loop_entry("Loops"), parts..., extension, "ext/x.jl" => "x = 1\n") do package
            triggers = "\n[weakdeps]\nRandom = \"9a3f8284-a2c9-5f02-9a11-845980a1fd5c\"\n\n[extensions]\nLoopsExt = \"Random\"\n"
            write(joinpath(package, "Project.toml"), read(joinpath(package, "Project.toml"), String) * triggers)
            loaded = Corset.Package.load(Corset.Discovery.discover(package; environment = nothing))
            @test isempty(loaded.errors)
            @test sort!([relpath(file.path, package) for file in loaded.sources.files]) == ["ext/LoopsExt.jl", "ext/x.jl", "src/Loops.jl", "src/a.jl", "src/b.jl", "src/c.jl", "src/e.jl"]
            line(span::Span)::Int = count(==(UInt8('\n')), codeunits(read(span.file, String))[1:(span.first_byte - 1)]) + 1
            spots = [(relpath(spot.span.file, package), line(spot.span), spot.cause) for spot in loaded.sources.blind_spots]
            # Loop includes files, but empty loop would not: its spot stays, as spots of branch, function body and macro do.
            @test [spot for spot in spots if last(spot) == "include with computed path"] == [("src/Loops.jl", line, "include with computed path") for line in (3, 6, 8, 11)]
            @test last(spots) == ("../shared.jl", 1, "computed include outside project") && length(spots) == 5
            @test Set(site.file.path for site in loaded.facts.methods) ⊇ Set(joinpath(package, "src", name) for name in ("a.jl", "Loops.jl"))
            # Run of one file checks its include closure only.
            single = Corset.Package.load(Corset.Discovery.discover(joinpath(package, "src", "a.jl"); environment = nothing))
            @test [relpath(file.path, package) for file in single.sources.files] == ["src/a.jl", "src/e.jl"]
        end
        # Package without precompile cache gives no include list: computed includes stay blind spots.
        with_package(parent, "Uncached", "src/Uncached.jl" => "__precompile__(false)\n" * loop_entry("Uncached"), parts...) do package
            loaded = Corset.Package.load(Corset.Discovery.discover(package; environment = nothing))
            @test [relpath(file.path, package) for file in loaded.sources.files] == ["src/Uncached.jl"]
            @test [spot.cause for spot in loaded.sources.blind_spots] == fill("include with computed path", 5)
        end
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
    # Safety is `warn` in every kind; only correctness denies.
    @test all(Config.preset_level(kind, Group.safety) == Level.warn for kind in instances(Kind.T))
    # Restriction rules are opt-in in every kind.
    @test all(Config.preset_level(kind, Group.restriction) == Level.allow for kind in instances(Kind.T))
    @test level(library, "broad-catch") == Level.warn
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
        # PrecompileTools switch shares table: config reads past it.
        write(joinpath(directory, "LocalPreferences.toml"), "[Corset]\nprecompile_workload = false\nkind = \"script\"\n")
        @test Config.read_table(joinpath(directory, "LocalPreferences.toml"), ("Corset",)).kind == "script"
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
    warned = Report([Diagnostic(possible, Level.warn, "test")], definite_only, @__DIR__, Dict{String, String}(), 0, 0, [], [])
    @test !Corset.Engine.failed(warned)
    strict = Config.settings(nothing, Flags(; deny_warnings = true), REGISTRY)
    @test Corset.Engine.failed(Report(warned.diagnostics, strict, @__DIR__, Dict{String, String}(), 0, 0, [], []))
end

@testset "coverage line lists three blind spots per cause" begin
    path = joinpath(@__DIR__, "f.jl")
    spot(line::Int, cause::String)::BlindSpot = BlindSpot(cause, Span(path, 2line - 1, 2line - 1, Precision.line))
    spots = [spot(5, "macro"); [spot(line, "include") for line in 1:5]]
    report = Report([], Config.settings(nothing, Flags(), REGISTRY), @__DIR__, Dict(path => "a\nb\nc\nd\ne\n"), 1, 0, [], spots)
    @test sprint(Corset.Render.render_coverage, report) == """
        coverage: analyzed 1 file; skipped 6 (include: 5, macro: 1)
          - f.jl:1:1: include
          - f.jl:2:1: include
          - f.jl:3:1: include
          - 2 more: include
          - f.jl:5:1: macro
        """
    # Work limit blind spots add warning: calls to those methods trust names.
    @test isnothing(Corset.CLI.budget_warning(report))
    budget = Report([], report.settings, @__DIR__, report.sources, 1, 0, [], [spot(1, "effects budget"), spot(2, "effects budget"), spot(3, "macro")])
    @test Corset.CLI.budget_warning(budget) == "corset: warning: effects work limit gave 2 blind spots; calls to those methods trust `!` names (`possible`)"
    @test endswith(something(Corset.CLI.budget_warning(Report([], report.settings, @__DIR__, report.sources, 1, 0, [], [spot(1, "effects budget")]))), "gave 1 blind spot; calls to those methods trust `!` names (`possible`)")
end

@testset "opt-outs" begin
    report = Corset.check(joinpath(@__DIR__, "optout", "cases.jl"))
    lines = Dict(path => Corset.Facts.line_starts(text) for (path, text) in report.sources)
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
    kept, problems = Corset.OptOuts.apply(Facts.FactSet([file], String[], Facts.Ban[], nothing, nothing, nothing, nothing, nothing, nothing), Finding[], Set([Symbol("one-letter")]))
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

"""Cases of `Package.probed`: package code tests each `probed_` function for methods, and no `kept_` function."""
module ProbedCases
    probed_direct(x::Float64) = x
    probed_qualified(x::Float64) = x
    probed_wrapped(x::Float64) = x
    probed_rewrapped(x::Float64) = x
    probed_splat(x::Float64) = x
    probed_local(x::Float64) = x
    probed_bare(x::Float64) = x
    probed_interrupt(x::Float64) = x
    probed_method_error(x::Float64) = x
    probed_guarded(x::Float64) = x
    probed_object(x::Float64) = x
    probed_alias(x::Float64) = x
    probed_parametric(x::Float64) = x
    kept_filtered(x::Float64) = x
    kept_finally(x::Float64) = x
    kept_called(x::Float64) = x
    kept_scoped(x::Float64) = x
    const SCOPE = Base.ScopedValues.ScopedValue(0)
    direct(x) = applicable(probed_direct, x)
    qualified(x) = Base.hasmethod(probed_qualified, Tuple{typeof(x)})
    accepts(f, x) = applicable(f, x)
    accepts_again(f, x) = accepts(f, x)
    wrapped(x) = accepts(probed_wrapped, x)
    rewrapped(x) = accepts_again(probed_rewrapped, x)
    splat(xs...) = applicable(probed_splat, xs...)
    function aliased(x)
        target = probed_local
        return applicable(target, x)
    end
    bare(x) = try
        probed_bare(x)
    catch
        0
    end
    interrupt(x) = try
        probed_interrupt(x)
    catch caught
        caught isa InterruptException && rethrow(); 0
    end
    method_error(x) = try
        probed_method_error(x)
    catch caught
        caught isa MethodError ? 0 : rethrow()
    end
    filtered(x) = try
        kept_filtered(x)
    catch caught
        caught isa ArgumentError || rethrow(); 0
    end
    finally_only(x) = try
        kept_finally(x)
    finally
        flush(stdout)
    end
    called(x) = kept_called(x)
    call_or_zero(f, x) = try
        f(x)
    catch
        0
    end
    guarded(x) = call_or_zero(probed_guarded, x)
    function call_alias_or_zero(f, x)
        target = f
        return try
            target(x)
        catch
            0
        end
    end
    guarded_alias(x) = call_alias_or_zero(probed_alias, x)
    struct Guard
        fallback::Int
    end
    (guard::Guard)(f, x) = try
        f(x)
    catch
        guard.fallback
    end
    const guard = Guard(0)
    guarded_object(x) = guard(probed_object, x)
    struct Wrapper{T}
        fallback::T
    end
    (wrapper::Wrapper)(f, x) = try
        f(x)
    catch
        wrapper.fallback
    end
    const wrapper = Wrapper(0)
    guarded_parametric(x) = wrapper(probed_parametric, x)
    # `@with` opens `try` with scope; its handler rethrows.
    scoped(x) = Base.ScopedValues.@with SCOPE => 1 kept_scoped(x)
end

@testset "probed functions" begin
    bindings = [getglobal(ProbedCases, name) for name in names(ProbedCases; all = true)]
    owned = [value for value in bindings if value isa Function && parentmodule(value) === ProbedCases]
    # Methods of functions, types and callable objects, as package stage collects them.
    found = Corset.Package.probed(Corset.Package.lowered_bodies(unique!([method for value in bindings for method in methods(value) if method.module === ProbedCases])))
    @test sort!([String(nameof(value)) for value in owned if value in found]) == [
        "probed_alias", "probed_bare", "probed_direct", "probed_guarded", "probed_interrupt", "probed_local",
        "probed_method_error", "probed_object", "probed_parametric", "probed_qualified", "probed_rewrapped", "probed_splat",
        "probed_wrapped",
    ]
    # Lowering pops exception before return; optimized IR can return from handler directly.
    @test Corset.Package.swallows(Any[Core.EnterNode(2), Core.ReturnNode(0)], 1, 2)
    @test !Corset.Package.swallows(Any[Core.EnterNode(2), Core.ReturnNode()], 1, 2)
end

module UseCases
    struct Entry
        value::Union{Int, Set{Int}}
    end
    struct Wrapped{V}
        items::V
    end
    struct Boxed{T}
        values::Set{Int}
        tag::T
        Boxed{T}(values::Set{Int}, tag::T) where {T} = new{T}(values, tag)
    end
    abstract type Shape end
    Shape(items::Vector{Int}) = Wrapped(items)
    stored(values::Set{Int}) = Entry(values)
    forwarded(values::Set{Int}) = stored(values)
    function aliased(values::Set{Int})
        alias = values
        return Entry(alias)
    end
    captured(values::Set{Int}, keys::Vector{Int}) = map(key -> Entry(values), keys)
    keyword(values::Set{Int}; count::Int = 1) = Entry(values)
    keyword_caller(values::Set{Int}) = keyword(values; count = 2)
    # Default-argument method calls own function through `#self#`.
    stored_default(values::Set{Int}, count::Int = 1) = Entry(values)
    counted(values::Set{Int}, start::Int = 0) = start + length(values)
    dispatched(values::Vector{Int}) = sum(values)
    dispatched(values::Set{Int}) = Entry(values)
    overloaded(values::Vector{Int}) = dispatched(values)
    keyed(values::Set{Int}, count::Int) = Entry(values)
    keyed(values::Set{Int}, name::Symbol) = length(values)
    by_name(values::Set{Int}) = keyed(values, :total)
    by_literal(values::Set{Int}) = keyed(values, 1)
    mode = :total
    by_global(values::Set{Int}) = keyed(values, mode)
    by_constant_module(values::Set{Int}) = UseCases.stored(values)
    # Type application of constant values reaches its constructors; repeated local in one application is no cycle.
    boxed_int(values::Set{Int}) = Boxed{Int}(values, 1)
    boxed_paired(values::Set{Int}) = (T = Int; Boxed{Pair{T, T}}(values, 1 => 1))
    # Non-constant global callee: store through its current value counts.
    action = Entry
    by_open_global(values::Set{Int}) = action(values)
    # Blind spots: open callee, splat, vararg, keyword value, element.
    by_argument(callback, values::Set{Int}) = callback(values)
    holder = UseCases
    by_module(values::Set{Int}) = holder.stored(values)
    splatted(values::Set{Int}, counts::Tuple{Int}) = keyed(values, counts...)
    spread(lists::Set{Int}...) = length(lists)
    into_vararg(values::Set{Int}) = spread(values)
    named(; values::Set{Int}) = Entry(values)
    by_keyword(values::Set{Int}) = named(; values = values)
    nested(rows::Vector{Set{Int}}) = Entry(rows[1])
    each_closure(rows::Vector{Set{Int}}) = foreach(row -> Entry(row), rows)
    converted(::Type{T}, values::Set{Int}) where {T} = T(values)
    malformed(values::Set{Int}) = Vector{Int, Int}(values)
    self_assigned(values::Set{Int}) = (local callback; callback = callback; callback(values))
    self_applied(values::Set{Int}) = (local T; T = Vector{T}; T(values))
    # Other expressions need nothing: copy, parameter-typed field, resize.
    built(values::Set{Int}) = Entry(Set(values))
    wrapped(items::Vector{Int}) = Wrapped(items)
    shaped(items::Vector{Int}) = Shape(items)
    pushed(items::Vector{Int}) = (push!(items, 1); nothing)
end

@testset "argument uses" begin
    uses = Corset.Package.argument_uses(Corset.Package.lowered_bodies(Corset.Package.module_methods([UseCases])), Set([UseCases]))
    use(f::Function, position::Integer) = get(get(uses, only(Base.methods(f)), Dict{Int, Facts.ArgumentUse}()), position, nothing)
    stored(found::Union{Nothing, Facts.ArgumentUse}) = isnothing(found) ? nothing : found.stored
    entry, boxed = Any[Union{Int, Set{Int}}], Any[Set{Int}]
    @test all(f -> stored(use(f, 1)) == entry, [UseCases.stored, UseCases.forwarded, UseCases.aliased, UseCases.captured, UseCases.keyword, UseCases.keyword_caller, UseCases.by_literal, UseCases.by_global, UseCases.by_constant_module, UseCases.by_open_global])
    @test stored(use(UseCases.boxed_int, 1)) == stored(use(UseCases.boxed_paired, 1)) == boxed
    @test all(method -> stored(uses[method][1]) == entry, Base.methods(UseCases.stored_default)) && length(Base.methods(UseCases.stored_default)) == 2
    @test isnothing(use(UseCases.captured, 2)) && !any(method -> haskey(uses, method), Base.methods(UseCases.counted))
    # Callee method for other argument type and other `keyed` method store nothing.
    @test isnothing(use(UseCases.overloaded, 1)) && isnothing(use(UseCases.by_name, 1))
    blind = [UseCases.by_module, UseCases.splatted, UseCases.into_vararg, UseCases.by_keyword, UseCases.nested, UseCases.each_closure, UseCases.malformed, UseCases.self_assigned, UseCases.self_applied]
    @test all(f -> isnothing(use(f, 1)), blind) && isnothing(use(UseCases.by_argument, 2)) && isnothing(use(UseCases.converted, 2))
    @test all(f -> isnothing(use(f, 1)), [UseCases.built, UseCases.wrapped, UseCases.shaped, UseCases.pushed])
    # Package facts read closure bodies, which have no method site.
    facts = Corset.Package.package_facts([UseCases], [Corset.Syntax.parse_file(@__FILE__, read(@__FILE__, String), Role.package)])
    @test facts.uses[only(Base.methods(UseCases.captured))][1].stored == entry
end
