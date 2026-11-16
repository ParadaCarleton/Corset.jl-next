using Test: @test, @testset, @test_throws
using Corset: Corset
using Corset.Facts: InferenceFacts, Precision, BlindSpot, SyntaxFile, Role, PackageFacts, MethodSite, FailingCall, Confidence, call_arguments, source
using Corset.StandIns: FloatStandIn, IntStandIn, ArrayStandIn, DenseStandIn, FunctionStandIn, model_type
using Corset.Package: source_name
using Corset.Signatures: LIMIT
using Corset.Inference:
    TypedCode, infer_package, infer, mappings, statement_nodes, broadcast_node, callee_name, spells, untyped, throw_helper, callable, callee_text
using Corset.Widening: statement_call
using Base.Broadcast: broadcasted
using Corset.Inference:
    Store, Entry, Staged, entry_key, method_id, code_digest, staged_digest, method_index, instance, shape, constant_text, digest, names_package!, holds_gensym
using Corset.Inference: Record, records, crashed, last_crash, finished_store, open_journal, record!, method_label, log_file

const CASE = joinpath(@__DIR__, "inference", "InferenceCases")

"""Inference facts, blind spots and typed code of `InferenceCases` fixture package, loaded with case directory on load path."""
function case_facts()::Tuple{Module, Vector{SyntaxFile}, PackageFacts, InferenceFacts, Vector{BlindSpot}, Vector{TypedCode}}
    sources = Corset.Discovery.discover(CASE; environment = nothing)
    push!(LOAD_PATH, CASE)
    loaded = try
        Corset.Package.load(sources.project, sources.files)
    finally
        pop!(LOAD_PATH)
    end
    facts, spots, typed, _ = infer_package(loaded.facts, sources.files, nothing, nothing)
    return first(loaded.facts.modules), sources.files, loaded.facts, facts, spots, typed
end

const MODULE, FILES, PACKAGE, FACTS, SPOTS, TYPED = case_facts()
const FILE = only(file for file in FILES if basename(file.path) == "InferenceCases.jl")

"""Code that tests redefine, as edit and reload would: struct `Point`, methods `f` and `leveled`. `Partial` leaves its field undefined."""
module Redefined
    struct Point
        x::Int
    end
    f(x::Int) = 1
    @generated leveled(x) = :(1)
    struct Partial
        text::String
        Partial() = new()
    end
end

"""Typed code of method named `name` (source name for keyword body) on signature with argument types `arguments`."""
function typed(name::String, arguments::Type...)::TypedCode
    return only(
        code for code in TYPED if source_name(code.site.method) == name &&
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

"""Lazy broadcast that method returns unconsumed."""
lazy_scaled(xs) = broadcasted(*, xs, 0.5)

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
        @test only(code.result for code in TYPED if code.signature == only(methods(MODULE.free)).sig) == Any
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
        @test !any(code -> source_name(code.site.method) in unreached, TYPED)
        # Wrapper passes empty keyword splat, so body gets concrete signature.
        slurpy = [code for code in TYPED if source_name(code.site.method) == "slurpy"]
        @test length(slurpy) == 4 && all(code -> isconcretetype(code.signature), slurpy)
        # Calls reach `nest` with ever deeper tuples until limit.
        @test count(code -> code.site.method.name === :nest, TYPED) == LIMIT
        # Own signatures come before reached ones.
        @test findfirst(code -> code.site.method.name === :helper, TYPED) > findfirst(code -> code.site.method.name === :caller, TYPED)
    end
    @testset "definition sites" begin
        # Infix definition and callable object method once got no definition node.
        @test !isnothing(only(sites("⊕")).node) && typed("⊕", FloatStandIn, FloatStandIn).result == FloatStandIn
        @test !isnothing(only(site for site in PACKAGE.methods if Base.unwrap_unionall(site.method.sig).parameters[1] <: MODULE.Circle).node)
    end
    @testset "untyped arguments" begin
        # Typed keyword leaves positional `x` untyped.
        @test untyped(only(sites("hk"))) && !untyped(only(sites("keyed"))) && !untyped(only(sites("slurpy")))
        # Evaluator that macro adds at definition line takes more arguments than definition, so it gets line site.
        @test sort!([isnothing(site.node) for site in sites("evaluated")]) == [false, true]
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
        # Lowering gives method for omitted default first body line; its statements sit on definition line.
        @test all(span -> line(FILE, span.first_byte) == line_of("function padded"), typed("padded", FloatStandIn).spans)
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
    @testset "lazy broadcast" begin
        # Returned lazy broadcast has no consumer call, so it maps to no node.
        lazy = first(only(code_typed(lazy_scaled, (Vector{Float64},); optimize = false)))
        index = findfirst(statement -> (call = statement_call(statement); !isnothing(call) && callee_name(lazy, call) === :broadcasted), lazy.code)
        @test isnothing(broadcast_node(lazy, Union{Nothing, Corset.Facts.SyntaxNode}[nothing for _ in lazy.code], something(index)))
    end
    @testset "blind spots" begin
        unreached = ["lonely", "splatted", "first_of", "unreached", "joined", "hk"]
        @test spot_lines("untyped method no call reaches") == sort!(line_of.(unreached))
        @test spot_lines("argument without stand-in") == sort!(line_of.(["text", "mixed", "rewrapped"]))
        @test spot_lines("signatures over limit") == sort!(line_of.(["wide", "nest"]))
        @test spot_lines("inference gave no code") == [line_of("refused")]
        @test spot_lines("call fails on stand-in only") == [line_of("halved")]
        @test length(SPOTS) == 13
    end
    @testset "failing calls" begin
        failing(name::String)::Vector{FailingCall} = [call for call in FACTS.failing if text(call.declared) == name]
        # Two stand-in signatures fail at one statement: one fact. Span is exact though no later code reads call.
        broken = only(failing("broken"))
        @test (broken.callee, broken.confidence, text(broken.span)) == ("+", Confidence.definite, "x + nothing")
        # Splatted and keyword calls name inner callee; constructor with unknown parameters names its type.
        @test [only(failing(name)).callee for name in ("spread", "boxed", "rewrapped")] == ["max", "Circle", "Wrap"]
        @test only(failing("called_unit")).callee == repr(MODULE.unit)
        # Method for `UInt8` intersects declared `Integer`, so call may succeed.
        @test only(failing("oddly")).confidence == Confidence.possible
        @test all(name -> isempty(failing(name)), ("halved", "checked"))
    end
    @testset "engine infers only for inference rule" begin
        rules = [entry.name for entry in Corset.Rules.REGISTRY if entry.stage == Corset.Facts.Stage.inference]
        causes(level::Corset.Config.Level.T)::Set{String} = Set(
            spot.cause for spot in Corset.check(CASE; flags = Corset.Config.Flags(; levels = [string(rule) => level for rule in rules])).blind_spots
        )
        push!(LOAD_PATH, CASE)
        try
            @test "untyped method no call reaches" in causes(Corset.Config.Level.warn)
            @test !("untyped method no call reaches" in causes(Corset.Config.Level.allow))
        finally
            pop!(LOAD_PATH)
        end
    end
    @testset "method store" begin
        facts, spots, fresh, used = infer_package(PACKAGE, FILES, Store(), nothing)
        stored(code::TypedCode)::Bool = haskey(used, entry_key(code.site.method, code.signature))
        named(codes)::Vector{String} = sort!(unique([source_name(code.site.method) for code in codes]))
        @test facts.failing == FACTS.failing && facts.disruptions == FACTS.disruptions && spots == SPOTS && isnothing(last(infer_package(PACKAGE, FILES, nothing, nothing)))
        # Store keeps closures, keyword bodies and generated code, but no generated instance on closure type.
        @test named(code for code in fresh if !stored(code)) == ["generated_apply", "regenerated"]
        again = infer_package(PACKAGE, FILES, used, nothing)
        @test again[1].failing == facts.failing && again[1].disruptions == facts.disruptions && again[2] == spots && keys(again[4]) == keys(used) && !any(stored, again[3])
        refreshed(files::Vector{SyntaxFile}, store::Store)::Vector{String} = named(code for code in infer_package(PACKAGE, files, store, nothing)[3] if stored(code))
        # Edit of file invalidates its methods: their spans hold byte offsets.
        edited = [basename(file.path) == "callees.jl" ? Corset.Syntax.parse_file(file.path, file.text * "\n", file.role) : file for file in FILES]
        @test refreshed(edited, used) == ["increment", "isless", "step_of"]
        # Method whose code changed invalidates callers that read it, through `map` too.
        function stale(name::String)::Store
            id = method_id(only(methods(getglobal(MODULE, Symbol(name)))))
            return Store(key => Entry(entry.file, [read => (read == id ? "stale" : code) for (read, code) in entry.methods], entry.staged, entry.inferred) for (key, entry) in used)
        end
        @test refreshed(FILES, stale("increment")) == ["increment", "stepped"] && refreshed(FILES, stale("step_of")) == ["mapped", "step_of"]
        # Generator that gives other code invalidates entries that read its output.
        regenerated = Store(key => Entry(entry.file, entry.methods, [Staged(staged.method, staged.signature, staged.key, "stale") for staged in entry.staged], entry.inferred) for (key, entry) in used)
        @test refreshed(FILES, regenerated) == ["doubled", "redoubled"]
        # Method gone from table: entries that read it, or its generated code, infer again.
        gone = Store(key => Entry(entry.file, [entry.methods; "gone" => "code"], entry.staged, entry.inferred) for (key, entry) in used)
        signature = Corset.Inference.serialized(Tuple{Int})
        gone_staged = Store(key => Entry(entry.file, entry.methods, [entry.staged; Staged("gone", signature, "gone", "code")], entry.inferred) for (key, entry) in used)
        @test length(infer_package(PACKAGE, FILES, gone, nothing)[3]) == length(infer_package(PACKAGE, FILES, gone_staged, nothing)[3]) == length(fresh)
        # Redefined method keeps its id, so stored entry finds it; its code digest changes.
        before = only(methods(Redefined.f))
        Core.eval(Redefined, :(f(x::Int) = 2))
        after = invokelatest(() -> only(methods(Redefined.f)))
        @test method_id(before) == method_id(after) && code_digest(before) != code_digest(after)
        # Generator that gives other code for same signature changes staged digest.
        generated() = something(instance(only(methods(Redefined.leveled)), Tuple{typeof(Redefined.leveled), Int}))
        old = generated()
        Core.eval(Redefined, :(@generated leveled(x) = :(2)))
        @test staged_digest(old) != staged_digest(invokelatest(generated))
        # Index holds methods of analyzed files only, keyword bodies and closures included.
        index, ids = method_index(Dict(file.path => file for file in FILES))
        @test all(method -> any(file -> file.path == string(method.file), FILES), values(index)) && length(index) > length(PACKAGE.methods)
        @test all(site -> haskey(ids, site.method), PACKAGE.methods) && all(ids[method] == id for (id, method) in index)
    end
    @testset "crash journal" begin
        mktempdir() do directory
            @test isempty(records(directory)) && isnothing(last_crash(records(directory)))
            @test_throws ArgumentError infer_package(PACKAGE, FILES, nothing, open_journal(directory))
            journal = open_journal(directory)
            facts, spots, _, used = infer_package(PACKAGE, FILES, Store(), journal)
            # Each inference records start, then end with entry store keeps.
            written = records(directory)
            @test isempty(crashed(written)) && isnothing(last_crash(written)) && keys(finished_store(written)) == keys(used)
            @test count(record -> !record.finished, written) == count(record -> record.finished, written)
            # Start without end is crash; next run gives that key blind spot and no inference.
            site = only(sites("scale"))
            key = entry_key(site.method, first(code.signature for code in TYPED if code.site.method === site.method))
            record!(journal, Record(key, method_label(site.method), false, nothing))
            close(journal.io)
            crash = something(last_crash(records(directory)))
            @test crash.key == key && crash.label == "InferenceCases.scale at InferenceCases.jl:$(line_of("scale"))"
            again = open_journal(directory)
            @test again.crashed == Set([key])
            facts, spots, typed, _ = infer_package(PACKAGE, FILES, Store(), again)
            close(again.io)
            @test only(spot.span for spot in spots if spot.cause == "inference crashed process") == site.span
            @test !any(code -> entry_key(code.site.method, code.signature) == key, typed)
        end
        # Stderr of inference goes to crash log; normal end copies it to stderr.
        mktempdir() do directory
            empty = (Corset.Facts.InferenceFacts(FailingCall[], Corset.Facts.Disruption[], Corset.Facts.NarrowingLoss[]), Corset.Facts.BlindSpot[], nothing)
            text = mktemp() do path, io
                result = redirect_stderr(io) do
                    Corset.Engine.journaled(journal -> (println(stderr, "inner note"); empty), directory)
                end
                close(io)
                @test result == empty
                read(path, String)
            end
            @test text == "inner note\n" && read(log_file(directory), String) == "inner note\n"
            # Julia exception copies log text of its run too, then propagates.
            thrown = mktemp() do path, io
                redirect_stderr(io) do
                    @test_throws "inference failed" Corset.Engine.journaled(journal -> (println(stderr, "failing note"); error("inference failed")), directory)
                end
                close(io)
                read(path, String)
            end
            @test thrown == "failing note\n"
        end
    end
    @testset "package shape" begin
        parts = shape(PACKAGE)
        whole(name::String)::Bool = any(startswith("piracy $(only(file.path for file in FILES if basename(file.path) == name)) "), parts)
        # Pirate method makes its file count whole; macro output counts through code of methods that hold it.
        @test whole("callees.jl") && !whole("macros.jl") && !whole("callers.jl")
        @test count(startswith("method "), parts) == length(PACKAGE.methods) && !any(contains('#'), parts)
        @test "global $MODULE.counter $(digest(Int))" in parts && "constant $MODULE.declared $MODULE.declared" in parts
        @test any(startswith("constant $MODULE.unit "), parts) && allunique(parts)
        @test constant_text(MODULE.Circle) != constant_text(MODULE.Wrap) && constant_text(+) == "Base.+"
        @test constant_text(Union{Int, String}) == digest(Union{Int, String}) && constant_text(Int) != constant_text(Int32)
        @test constant_text(1) != constant_text(2) && constant_text("a") != constant_text("b") && constant_text((:a,)) != constant_text((:b,))
        @test constant_text(MODULE.fast) != constant_text(MODULE.slow) && constant_text((1, ("a", 'b'))) != constant_text((1, ("a", 'c')))
        # Value of other type counts by type: run can change mutable value.
        @test constant_text([1]) == constant_text([2]) != constant_text([1.0]) && constant_text((1, [2])) == constant_text((1, [3]))
        @test constant_text(MODULE.Wrap(1)) != constant_text(MODULE.Wrap(2)) && constant_text(MODULE.Wrap([1])) == constant_text(MODULE.Wrap([2]))
        @test constant_text(Redefined.Partial()) == digest(Redefined.Partial()) && constant_text(Ref(1)) == constant_text(Ref(2))
        # Struct that edit redefines serializes as before; its layout differs.
        point = Redefined.Point
        Core.eval(
            Redefined, :(
                struct Point
                    x::Float64
                end
            )
        )
        redefined = invokelatest(getglobal, Redefined, :Point)
        @test digest(point) == digest(redefined) && constant_text(point) != constant_text(redefined)
    end
    @testset "gensyms and package types" begin
        closure = typeof(x -> x)
        @test holds_gensym(closure) && holds_gensym(Union{Int, closure}) && holds_gensym(Vector{closure}) && holds_gensym(Tuple{closure, T} where {T})
        @test !holds_gensym(typeof(sin)) && !holds_gensym(Vector{Int}) && !holds_gensym(TypeVar(:T))
        named(type::Any)::Bool = names_package!(IdDict{Any, Bool}(), type, Set([MODULE]))
        @test named(Union{Int, MODULE.Wrap{Int}}) && named(Vector{T} where {T <: MODULE.Shape}) && named(Tuple{Vararg{MODULE.Shape}})
        @test !named(Tuple{Vararg}) && !named(Vector{Int}) && !named(1)
    end
    @testset "failing call helpers" begin
        helper(callee::Any)::Bool = first(throw_helper(callee))
        @test helper(throw) && helper(error) && helper(rethrow)
        # Builtin, function without methods, and function that returns for some argument types are no helpers.
        @test !helper(Core.tuple) && !helper(MODULE.declared) && !helper(MODULE.single)
        # Signature that misses method gives no code.
        @test isnothing(infer(only(methods(MODULE.single)), Tuple{typeof(MODULE.single), Float64}))
        @test callable(Core.Const(sin)) === sin && callable(Type{Int}) === Int
        @test callable(Type{MODULE.Wrap{T}} where {T}) === MODULE.Wrap
        @test isnothing(callable(Type{<:MODULE.Wrap})) && isnothing(callable(Function))
        @test callee_text(MODULE.Wrap) == "Wrap" && callee_text(Union{Int, String}) == "Union{Int64, String}"
        @test model_type(Tuple{typeof(sin), FloatStandIn, ArrayStandIn{IntStandIn, 2}, MODULE.Circle{FloatStandIn}}) ==
            Tuple{typeof(sin), Float32, Matrix{Int32}, MODULE.Circle{Float32}}
        @test model_type(DenseStandIn{FloatStandIn, 1}) == Vector{Float32} && model_type(FunctionStandIn) == FunctionStandIn
    end
end
