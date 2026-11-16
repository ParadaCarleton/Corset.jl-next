using Test: @test, @testset, @test_throws
using Corset: Corset
using Corset.Narrowing: Narrowing, Flow, losses, meet, Proven

"""Methods whose narrowing `Narrowing.losses` scans; `Main` callers see them through this module."""
module NarrowingCases
    guarded(x) = ((x isa Expr && x.head === :call) || return nothing; x.args)
    split_guard(x) = (x isa Expr || return nothing; x.head === :call || return nothing; x.args)
    function looped(items::Vector{Any})
        total = 0
        for item in items
            (item isa Vector && !isempty(item)) || continue
            total += length(item)
        end
        return total
    end
    function retried(x, y)
        (x isa Expr && x.head === :call) || return nothing
        try
            x = y
            error("retry")
        catch
            return x.args
        end
    end
    stored(entries::Union{Nothing, Vector{Int}}) = (missing_entries = entries === nothing || isempty(entries); missing_entries && return 0; first(entries))
    function paired(entries::Union{Nothing, Vector{Int}}, count)
        missing_entries = entries === nothing || !(count isa Int)
        missing_entries && return 0
        return first(entries) + count
    end
    reassigned(x, y) = ((x isa Expr && x.head === :call) || return nothing; x = y; x)
    function restored(x, y)
        called = x isa Expr && x.head === :call
        x = y
        called || return nothing
        return x
    end
    dynamic(x, type::Type) = ((x isa type && x !== 1) || return nothing; x)
    rejected(x) = ((x isa Expr && x.head === :call) || throw(ArgumentError("call")); x.args)
end

"""Losses in `f` on argument types `arguments`, as (variable, narrowed type, found type)."""
function scanned(f::Function, arguments::Type...)::Vector{Tuple{Symbol, Type, Type}}
    instance, code, _, _, flow = something(Corset.Inference.infer(only(methods(f)), Tuple{typeof(f), arguments...}))
    return [(code.slotnames[loss.slot], loss.narrowed, loss.found) for loss in losses(code, flow, Core.Compiler.sptypes_from_meth_instance(instance))]
end

@testset "narrowing" begin
    cases = NarrowingCases
    @testset "guard value loses type test" begin
        @test scanned(cases.guarded, Any) == [(:x, Expr, Any)]
        @test scanned(cases.looped, Vector{Any}) == [(:item, Vector, Any)]
        @test scanned(cases.stored, Union{Nothing, Vector{Int}}) == [(:entries, Vector{Int}, Union{Nothing, Vector{Int}})]
        @test scanned(cases.rejected, Any) == [(:x, Expr, Any)]
        # `entries === nothing` read again on its own true branch never gives `false`, so other path keeps `count` fact.
        @test scanned(cases.paired, Union{Nothing, Vector{Int}}, Any) == [(:entries, Vector{Int}, Union{Nothing, Vector{Int}}), (:count, Int, Any)]
    end
    @testset "narrowing inference keeps" begin
        @test isempty(scanned(cases.split_guard, Any))
        @test isempty(scanned(cases.guarded, Expr))
        # Handler runs after assignment in `try` body, so test before `try` proves nothing there.
        @test isempty(scanned(cases.retried, Any, Any))
        @test isempty(scanned(cases.reassigned, Any, Any))
        # Assignment after stored condition ends what condition proves about variable.
        @test isempty(scanned(cases.restored, Any, Any))
        # Type in variable is no constant type test.
        @test isempty(scanned(cases.dynamic, Any, Type))
    end
    @testset "join" begin
        left, right = Proven(1 => (Int, 3), 2 => (Expr, 4)), Proven(1 => (Float64, 2))
        @test meet(left, right) == Proven(1 => (Union{Int, Float64}, 2))
        @test meet(nothing, right) === right && meet(left, nothing) === left
    end
    @testset "graph must cover code" begin
        instance, code, _, _, flow = something(Corset.Inference.infer(only(methods(cases.guarded)), Tuple{typeof(cases.guarded), Any}))
        short = Flow(flow.graph, flow.tables[1:(end - 1)])
        @test_throws "control flow graph does not cover typed code" losses(code, short, Core.Compiler.sptypes_from_meth_instance(instance))
    end
end
