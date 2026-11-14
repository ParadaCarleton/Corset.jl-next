using Test: @test, @testset
using Corset: Corset
using Corset.Facts: InferenceFacts, TypedCode, Precision, BlindSpot, SyntaxFile, Role, PackageFacts, MethodSite, call_arguments, source
using Corset.StandIns: FloatStandIn, IntStandIn, ArrayStandIn
using Corset.Package: source_name
using Corset.Signatures: LIMIT
using Corset.Inference: inference_facts, infer, mappings, statement_nodes, statement_call, callee_name, spells, untyped

const CASE = joinpath(@__DIR__, "inference", "InferenceCases")

"""Inference facts and blind spots of `InferenceCases` fixture package, loaded with case directory on load path."""
function case_facts()::Tuple{Module, Vector{SyntaxFile}, PackageFacts, InferenceFacts, Vector{BlindSpot}}
    sources = Corset.Discovery.discover(CASE; environment = nothing)
    push!(LOAD_PATH, CASE)
    loaded = try
        Corset.Package.load(sources.project, sources.files)
    finally
        pop!(LOAD_PATH)
    end
    facts, spots = inference_facts(loaded.facts, sources.files)
    return first(loaded.facts.modules), sources.files, loaded.facts, facts, spots
end

const MODULE, FILES, PACKAGE, FACTS, SPOTS = case_facts()
const FILE = only(file for file in FILES if basename(file.path) == "InferenceCases.jl")

"""Typed code of method named `name` (source name for keyword body) on signature with argument types `arguments`."""
function typed(name::String, arguments::Type...)::TypedCode
    return only(
        code for code in FACTS.typed if source_name(code.site.method) == name &&
            collect(Base.unwrap_unionall(code.signature).parameters[2:end]) == collect(arguments)
    )
end

"""Source text of `span` in its file."""
text(span::Corset.Facts.Span)::String = (file = only(file for file in FILES if file.path == span.file); file.text[span.first_byte:thisind(file.text, span.last_byte)])

"""Source text of each exact span of `code`."""
exact(code::TypedCode)::Vector{String} = [text(span) for span in code.spans if span.precision == Precision.exact]

"""Line of byte `byte` in `file`."""
line(file::SyntaxFile, byte::Int)::Int = count(==(UInt8('\n')), codeunits(file.text)[1:byte]) + 1

"""Lines of blind spots with `cause`."""
spot_lines(cause::String)::Vector{Int} = sort!([line(FILE, spot.span.first_byte) for spot in SPOTS if spot.cause == cause])

"""Method sites of methods with source name `name`; keyword body included."""
sites(name::String)::Vector{MethodSite} = [site for site in PACKAGE.methods if source_name(site.method) == name]

"""Line where definition of function `name` starts in fixture."""
line_of(name::String)::Int = findfirst(line -> occursin(Regex("^(@generated )?$name\\("), line), split(FILE.text, '\n'))

"""Span of first statement of `code` that calls function `name`."""
call_span(code::TypedCode, name::Symbol)::Corset.Facts.Span = code.spans[
    findfirst(statement -> (call = statement_call(statement); !isnothing(call) && callee_name(code.code, call) === name), code.code.code),
]

@testset "inference stage" begin
    @testset "stand-in signatures infer" begin
        @test typed("scale", FloatStandIn, IntStandIn).result == FloatStandIn
        @test typed("scale", IntStandIn, IntStandIn).result == IntStandIn
        @test typed("area", MODULE.Circle{FloatStandIn}).result == FloatStandIn
        @test typed("broken", FloatStandIn).result == Union{}
        @test typed("total", ArrayStandIn{IntStandIn, 1}).result == IntStandIn
        @test typed("explicit", Any, FloatStandIn).result == FloatStandIn
        # `_` binds nothing, so method counts as typed.
        @test typed("ignored", Any, FloatStandIn).result == FloatStandIn
        # Free type variable keeps declared signature.
        @test only(code.result for code in FACTS.typed if code.signature == only(methods(MODULE.free)).sig) == Any
    end
    @testset "calls reach untyped methods" begin
        @test typed("helper", FloatStandIn).result == FloatStandIn
        # Literal `2` is `Int`, which integer stand-in loses to, as `Int32` does.
        @test typed("helper", IntStandIn).result == Int
        @test typed("keyed", Int, typeof(MODULE.keyed), FloatStandIn).result == FloatStandIn
        # Method for omitted default value calls full method with default.
        @test typed("defaulted", FloatStandIn, Int).result == FloatStandIn
        @test typed("assigned", FloatStandIn).result == FloatStandIn
        @test typed("radius_of", MODULE.Circle{FloatStandIn}).result == FloatStandIn
        unreached = ("lonely", "splatted", "first_of", "unreached", "joined", "hk")
        @test !any(code -> source_name(code.site.method) in unreached, FACTS.typed)
        # Wrapper passes empty keyword splat, so body gets concrete signature.
        slurpy = [code for code in FACTS.typed if source_name(code.site.method) == "slurpy"]
        @test length(slurpy) == 4 && all(code -> isconcretetype(code.signature), slurpy)
        # Calls reach `nest` with ever deeper tuples until limit.
        @test count(code -> code.site.method.name === :nest, FACTS.typed) == LIMIT
        # Own signatures come before reached ones.
        @test findfirst(code -> code.site.method.name === :helper, FACTS.typed) > findfirst(code -> code.site.method.name === :caller, FACTS.typed)
    end
    @testset "definition sites" begin
        # Infix definition and callable object method once got no definition node.
        @test !isnothing(only(sites("⊕")).node) && typed("⊕", FloatStandIn, FloatStandIn).result == FloatStandIn
        @test !isnothing(only(site for site in PACKAGE.methods if Base.unwrap_unionall(site.method.sig).parameters[1] <: MODULE.Circle).node)
    end
    @testset "untyped arguments" begin
        # Typed keyword leaves positional `x` untyped.
        @test untyped(only(sites("hk"))) && !untyped(only(sites("keyed"))) && !untyped(only(sites("slurpy")))
        # Method for omitted default leaves out untyped `y`.
        @test sort!(untyped.(sites("defaulted"))) == [false, true]
    end
    @testset "callee check" begin
        file = Corset.Syntax.parse_file("calls.jl", "f(a, b)\na + b + c\nf(a; k = 1)\n-a\nf[a]\n", Role.package)
        call(index::Int)::Corset.Facts.SyntaxNode = Corset.Facts.children_of(file.tree)[index]
        @test spells(file, call(1), :f, 2) && !spells(file, call(1), :f, 1) && !spells(file, call(1), :g, 2)
        @test spells(file, call(2), :+, 3) && spells(file, call(3), :f, 1) && spells(file, call(4), :-, 1)
        # Lowering inserts `getindex`, so any node passes.
        @test spells(file, call(1), :getindex, 5) && !spells(file, file.tree, :f, 0) && !spells(file, call(5), :f, 1)
        @test [source(file, argument) for argument in call_arguments(call(2))] == ["a", "b", "c"]
    end
    @testset "spans" begin
        # Callee read maps to operator; call maps to whole expression.
        @test exact(typed("scale", FloatStandIn, IntStandIn)) == ["*", "x * factor"]
        @test ["shape.radius", "pi * shape.radius^2"] ⊆ exact(typed("area", MODULE.Circle{FloatStandIn}))
        @test "x * factor" in exact(typed("keyed", Int, typeof(MODULE.keyed), FloatStandIn))
        # Repeated `abs(x)` maps to two nodes, so neither call gets exact span.
        @test exact(typed("nested", FloatStandIn)) == ["+", "abs(abs(x))", "abs(abs(x)) + abs(x)"]
        # Wrapper call into keyword body maps to no node that spells it.
        wrapper = typed("keyed", FloatStandIn)
        @test isempty(exact(wrapper)) && all(span -> span.precision == Precision.line, wrapper.spans)
        @test all(span -> span.precision == Precision.line, typed("doubled", FloatStandIn).spans)
        made = typed("made", FloatStandIn)
        @test isnothing(made.site.node) && all(span -> span.precision == Precision.line, made.spans)
        @test length(Set(line(FILE, span.first_byte) for span in made.spans)) == 2
        # Loop statements without exact span sit on their own line inside definition.
        loop = typed("total", ArrayStandIn{FloatStandIn, 1})
        lines = Set(line(FILE, span.first_byte) for span in loop.spans)
        @test lines ⊆ line_of("function total"):(line_of("function total") + 6) && length(lines) > 2
        # Same-file macro body line lies outside definition; method span stands in.
        bumped = typed("bumped", FloatStandIn)
        @test call_span(bumped, :+) == bumped.site.span
        # Macro of other file: outermost scope is call site.
        twice = typed("bumped_twice", FloatStandIn)
        uses = twice.site.file
        @test call_span(twice, :+).precision == Precision.line && line(uses, call_span(twice, :+).first_byte) == 2
    end
    @testset "calls of one callee map in evaluation order" begin
        code = typed("twice", FloatStandIn)
        instance = first(infer(code.site.method, code.signature))
        mapped = mappings(code.code, instance, code.site)
        calls = findall(statement -> (call = statement_call(statement); !isnothing(call) && callee_name(code.code, call) === :abs), code.code.code)
        @test text.(code.spans[calls]) == ["abs(x)", "abs(-x)"]
        mapped[calls] = mapped[reverse(calls)]
        swapped = statement_nodes(code.code, mapped, code.site.file)
        @test !isnothing(swapped[first(calls)]) && isnothing(swapped[last(calls)])
    end
    @testset "blind spots" begin
        unreached = ["lonely", "splatted", "first_of", "unreached", "joined", "hk"]
        @test spot_lines("untyped method no call reaches") == sort!(line_of.(unreached))
        @test spot_lines("argument without stand-in") == sort!(line_of.(["text", "mixed"]))
        @test spot_lines("signatures over limit") == sort!(line_of.(["wide", "nest"]))
        @test spot_lines("inference gave no code") == [line_of("refused")]
        @test length(SPOTS) == 11
    end
end
