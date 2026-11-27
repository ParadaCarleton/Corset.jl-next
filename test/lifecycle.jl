using Test: @test, @test_throws, @testset
using Corset: Corset
using Corset.Facts: Facts, ArrayLife, AllocationKind, ArrayEventKind, Coverage, ArrayPath
using Corset.Inference: infer_package
using Corset.Effects: Effects
using Corset.Lifecycle: lifecycle_facts

const CASE = joinpath(@__DIR__, "lifecycle", "LifecycleCases")

"""Fixture module and `lifecycle` stage facts of `LifecycleCases`."""
function case_facts()::Tuple{Module, Facts.LifecycleFacts}
    sources = Corset.Discovery.discover(CASE; environment = nothing)
    push!(LOAD_PATH, CASE)
    loaded = try
        Corset.Package.load(sources)
    finally
        pop!(LOAD_PATH)
    end
    _, _, units, _ = infer_package(loaded.facts, loaded.sources.files, nothing, nothing)
    run = Effects.effects_facts(loaded.facts, units, nothing, Effects.Summaries.Library())
    return first(loaded.facts.modules), lifecycle_facts(loaded.facts, run.ordered)
end

const CASES, FACTS = case_facts()

"""Arrays that fixture method `name` allocates; fixture names are unique."""
arrays(name::Symbol)::Vector{ArrayLife} = only(found for found in FACTS.methods if found.site.method.name == name).arrays

"""Kind, coverage, indices, path and view flag of each event of `array`."""
events(array::ArrayLife)::Vector{Tuple{ArrayEventKind.T, Coverage.T, Vector{Int}, ArrayPath.T, Bool}} =
    [(event.kind, event.coverage, event.indices, event.path, event.view) for event in array.events]

const SHAPE, READ, WRITE, RESIZE, ESCAPE, JOINED = ArrayEventKind.shape, ArrayEventKind.read, ArrayEventKind.write, ArrayEventKind.resize, ArrayEventKind.escape, ArrayEventKind.joined
const WHOLE, ELEMENT, UNKNOWN = Coverage.whole, Coverage.element, Coverage.unknown
const SURE, BRANCH, LOOP = ArrayPath.sure, ArrayPath.branch, ArrayPath.loop

"""Events of only array that fixture method `name` allocates."""
only_events(name::Symbol)::Vector{Tuple{ArrayEventKind.T, Coverage.T, Vector{Int}, ArrayPath.T, Bool}} = events(only(arrays(name)))

@testset "allocation kinds and dimensions" begin
    kinds = [
        :undef_read => AllocationKind.undef, :similar_sum => AllocationKind.undef, :filled_constant => AllocationKind.filled,
        :broadcast_sum => AllocationKind.broadcast, :collected_sum => AllocationKind.collected, :slice_sum => AllocationKind.slice,
        :copied_head => AllocationKind.copied, :filled_whole => AllocationKind.undef,
    ]
    for (name, kind) in kinds
        @test only(arrays(name)).kind == kind
    end
    @test only(arrays(:filled_constant)).dimensions == [3] && only(arrays(:filled_whole)).dimensions == [3]
    @test only(arrays(:resized)).dimensions == [0] && isnothing(only(arrays(:similar_sum)).dimensions)
    @test only(arrays(:tuple_size)).dimensions == [2, 3]
    # Package call result is no allocation of caller; package method reports its own.
    @test !any(found -> found.site.method.name == :from_helper, FACTS.methods)
    # Generated method lowers other code per unit: its arrays are blind spot.
    @test !any(found -> found.site.method.name == :generated_sum, FACTS.methods) && CASES.generated_sum([1.0]) == 1.0
    @test [spot.cause for spot in FACTS.blind_spots] == [Corset.Lifecycle.GENERATED_ARRAY]
    @test only_events(:helper) == [(ESCAPE, UNKNOWN, Int[], SURE, false)]
    @test all(found -> all(array -> issorted(event.order for event in array.events), found.arrays), FACTS.methods)
end

@testset "event kinds" begin
    @test only_events(:undef_read) == [(WRITE, ELEMENT, [1], SURE, false), (READ, ELEMENT, [2], SURE, false)]
    @test only_events(:filled_constant) == [(WRITE, ELEMENT, [1], SURE, false), (READ, WHOLE, Int[], SURE, false)]
    for name in (:similar_sum, :broadcast_sum, :collected_sum, :slice_sum, :copied_into, :guarded_read)
        @test only_events(name) == [(READ, WHOLE, Int[], SURE, false)]
    end
    @test only_events(:copied_head) == [(WRITE, ELEMENT, [1], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    @test only_events(:shape_only) == [(SHAPE, UNKNOWN, Int[], SURE, false), (SHAPE, UNKNOWN, Int[], SURE, false)]
    @test [event.callee for event in only(arrays(:shape_only)).events] == [:length, :size]
    @test [event.position for event in only(arrays(:shape_only)).events] == [1, 1]
    # `isassigned` tests element without read.
    @test only_events(:assigned_only) == [(SHAPE, UNKNOWN, Int[], SURE, false)] && !CASES.assigned_only(1)
    @test only(only(arrays(:copied_into)).events).position == 2
    @test only(only(arrays(:keyword_sum)).events).position == 1
    # Operator through local alias is constant in IR.
    @test only(only(arrays(:concatenated)).events).operator == :vcat
    @test isnothing(only(only(arrays(:keyword_sum)).events).operator)
    @test only_events(:viewed) == [(WRITE, WHOLE, Int[], SURE, true), (READ, WHOLE, Int[], SURE, false)]
    @test only_events(:resized) == [(RESIZE, UNKNOWN, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    # Collection that keeps array is escape of unknown extent.
    @test only_events(:stored) == [(ESCAPE, UNKNOWN, Int[], SURE, false)]
    # `!` call writes first operand it can write: immutable functor is skipped.
    for name in (:functor_first, :reduced_functors)
        @test only_events(name) == [(WRITE, UNKNOWN, Int[], SURE, false), (READ, WHOLE, Int[], SURE, false)]
    end
    @test only_events(:mapped_functor) == [(WRITE, WHOLE, Int[], SURE, false), (READ, WHOLE, Int[], SURE, false)]
    # Mutable functor can be written: package call can write operands after it, library call writes subject after it.
    for name in (:tallied_first, :tallied_map, :tallied_reduce)
        @test only_events(name) == [(ESCAPE, UNKNOWN, Int[], SURE, false), (READ, WHOLE, Int[], SURE, false)]
    end
    @test events(last(arrays(:second_output))) == [(ESCAPE, UNKNOWN, Int[], SURE, false), (READ, WHOLE, Int[], SURE, false)]
    @test all(==(6.0), (CASES.functor_first([1.0, 2.0]), CASES.mapped_functor([1.0, 2.0]), CASES.reduced_functors([1.0, 2.0])))
    @test all(==(3.0), (CASES.tallied_first([1.0, 2.0]), CASES.tallied_map([1.0, 2.0]), CASES.tallied_reduce([1.0, 2.0])))
    @test CASES.second_output() == 6.0
    # Mapping gives both allocations of `twins` one span.
    @test allequal(array.site for array in arrays(:twins))
    @test events.(arrays(:twins)) == [[(WRITE, WHOLE, Int[], SURE, false)], [(READ, WHOLE, Int[], SURE, false)]]
    @test only_events(:filled_whole) == [(WRITE, WHOLE, Int[], SURE, false), (READ, WHOLE, Int[], SURE, false)]
    @test first(only(arrays(:filled_whole)).events).callee == :fill!
    @test only_events(:unknown_write) == [(READ, WHOLE, Int[], SURE, false), (WRITE, UNKNOWN, Int[], SURE, false), (READ, ELEMENT, [1], SURE, false)]
    @test [events(array) for array in arrays(:joined)] == [[(JOINED, UNKNOWN, Int[], SURE, false)], [(JOINED, UNKNOWN, Int[], SURE, false)]]
    captured, mapped = arrays(:captured)
    # Closure captures array: it escapes, so later uses through closure stay unseen.
    @test events(captured) == [(READ, WHOLE, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    @test mapped.kind == AllocationKind.collected && events(mapped) == [(ESCAPE, UNKNOWN, Int[], SURE, false)]
end

@testset "prefix writes" begin
    @test only_events(:prefix_copy) == [(WRITE, UNKNOWN, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    for name in (:source_copy, :counted_map)
        @test only_events(name) == [(WRITE, WHOLE, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    end
    @test only_events(:self_map) == [(READ, WHOLE, Int[], SURE, false), (WRITE, WHOLE, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    # `fill!` stores array in itself without reading elements; source that `pop!` shrinks proves no extent.
    @test only_events(:self_fill) == [(WRITE, WHOLE, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    @test only_events(:shrunk_copy) == [(WRITE, UNKNOWN, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    # `sort!` and one-array `map!` read old elements before they write.
    @test only_events(:sorted) == [(READ, WHOLE, Int[], SURE, false), (WRITE, UNKNOWN, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    @test only_events(:mapped_in_place) == [(READ, WHOLE, Int[], SURE, false), (WRITE, WHOLE, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    @test_throws UndefRefError CASES.sorted(2)
    @test_throws UndefRefError CASES.mapped_in_place(2)
    @test isassigned(CASES.self_fill(), 2) && !isassigned(CASES.shrunk_copy(["a", "b"]), 2)
    # Runtime: short source leaves tail unassigned; array as own source reads unassigned element.
    @test !isassigned(CASES.prefix_copy(3), 2) && isassigned(CASES.source_copy(["a", "b"]), 2) && isassigned(CASES.counted_map(["a", "b"]), 2)
    @test_throws UndefRefError CASES.self_map(2)
end

@testset "paths" begin
    @test only_events(:iterated) == [(READ, WHOLE, Int[], SURE, false), (READ, WHOLE, Int[], LOOP, false)]
    @test only_events(:branch_write) == [(WRITE, ELEMENT, [1], BRANCH, false), (READ, WHOLE, Int[], SURE, false)]
    @test only_events(:loop_read) == [(READ, WHOLE, Int[], LOOP, false)]
end

@testset "fill loops" begin
    shaped = [(SHAPE, UNKNOWN, Int[], SURE, false), (WRITE, WHOLE, Int[], SURE, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    for name in (:fill_each, :fill_counted, :fill_cartesian)
        @test only_events(name) == shaped
    end
    # Fill loop write is no call: it has no operand position.
    @test isnothing(only(arrays(:fill_each)).events[2].position)
    for name in (:fill_source, :fill_extent)
        @test only_events(name) == shaped[2:3]
    end
    # Source that `pop!` shrinks covers fewer elements than allocation.
    for name in (:partial_fill, :shrunk_fill)
        @test only_events(name) == [(WRITE, UNKNOWN, Int[], LOOP, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    end
    for name in (:break_fill, :branch_fill)
        @test only_events(name) == [(SHAPE, UNKNOWN, Int[], SURE, false), (WRITE, UNKNOWN, Int[], LOOP, false), (ESCAPE, UNKNOWN, Int[], SURE, false)]
    end
    # Fill loop writes every element; loop that can skip one leaves it unassigned.
    assigned(array::AbstractArray)::Bool = all(index -> isassigned(array, index), eachindex(array))
    strings = ["a", "b", "c"]
    @test assigned(CASES.fill_each(strings)) && assigned(CASES.fill_source(view(strings, 1:2))) && assigned(CASES.fill_extent(3))
    @test assigned(CASES.fill_counted(strings)) && assigned(CASES.fill_cartesian(["a" "b"; "c" "d"]))
    @test !isassigned(CASES.partial_fill(3), 1) && !isassigned(CASES.shrunk_fill(["a", "b"]), 2)
    @test !isassigned(CASES.break_fill(["a", "", "c"]), 2) && !isassigned(CASES.branch_fill(["a", "", "c"]), 2)
    @test_throws UndefRefError CASES.undef_read(2)
end

@testset "rebind pairs" begin
    for (name, same_axes) in (:rebound => false, :scaled => true)
        earlier, later = arrays(name)
        @test isnothing(earlier.rebind) && later.kind == AllocationKind.broadcast
        @test something(later.rebind).earlier == earlier.site && something(later.rebind).same_axes == same_axes
        @test something(later.rebind).same_type && something(later.rebind).exclusive
        @test events(earlier) == [(JOINED, UNKNOWN, Int[], LOOP, false), (JOINED, UNKNOWN, Int[], SURE, false)]
        @test events(later) == [(JOINED, UNKNOWN, Int[], SURE, false), (JOINED, UNKNOWN, Int[], BRANCH, false)]
    end
    # Stored array: in-place broadcast would change it.
    @test !something(only(array for array in arrays(:shared) if !isnothing(array.rebind)).rebind).exclusive
end

@testset "units merge per method" begin
    span(first_byte::Int)::Facts.Span = Facts.Span("case.jl", first_byte, first_byte, Facts.Precision.line)
    event(path::ArrayPath.T)::Facts.ArrayEvent = Facts.ArrayEvent(span(5), READ, WHOLE, Int[], path, :sum, 1, nothing, false, 2)
    write = Facts.ArrayEvent(span(3), WRITE, ELEMENT, [1], SURE, :setindex!, 1, nothing, false, 1)
    life(dimensions::Vector{Int}, events::Vector{Facts.ArrayEvent}, rebind::Union{Nothing, Facts.Rebind})::ArrayLife =
        ArrayLife(span(1), 1, AllocationKind.filled, dimensions, events, rebind)
    merged = Corset.Lifecycle.merged_array([life([2], [event(SURE)], Facts.Rebind(span(9), true, true, false)), life([3], [event(LOOP), write], Facts.Rebind(span(9), false, true, true))])
    # Each event once with its worst path, in statement order; event that one unit lacks is `branch` at best.
    @test events(merged) == [(WRITE, ELEMENT, [1], BRANCH, false), (READ, WHOLE, Int[], LOOP, false)]
    @test events(Corset.Lifecycle.merged_array([life([2], [write], nothing), life([2], [write], nothing)])) == [(WRITE, ELEMENT, [1], SURE, false)]
    # Source statement tells apart allocations of one span, also when unit lacks one of them.
    @test Corset.Lifecycle.array_key(life([2], [write], nothing)) != Corset.Lifecycle.array_key(ArrayLife(span(1), 2, AllocationKind.filled, [2], [write], nothing))
    # Dimensions only when units agree.
    @test isnothing(merged.dimensions) && merged.rebind == Facts.Rebind(span(9), false, true, false)
    @test Corset.Lifecycle.merged_array([life([2], [event(BRANCH)], nothing), life([2], [event(SURE)], nothing)]).dimensions == [2]
    @test isnothing(Corset.Lifecycle.merged_rebind(Union{Nothing, Facts.Rebind}[Facts.Rebind(span(9), true, true, true), nothing]))
    @test isnothing(Corset.Lifecycle.merged_rebind(Union{Nothing, Facts.Rebind}[Facts.Rebind(span(9), true, true, true), Facts.Rebind(span(8), true, true, true)]))
end

@testset "holder types" begin
    held = Vector{Float64}
    @test Effects.can_hold(Vector{Vector{Float64}}, held, Effects.HOLD_DEPTH) && Effects.can_hold(Any, held, Effects.HOLD_DEPTH)
    @test Effects.can_hold(Union{Nothing, Tuple{Vector{Float64}, Int}}, held, Effects.HOLD_DEPTH)
    @test !Effects.can_hold(Vector{Float64}, held, Effects.HOLD_DEPTH) && !Effects.can_hold(Tuple{Int, String}, held, Effects.HOLD_DEPTH)
    @test !Effects.can_hold(Union{}, held, Effects.HOLD_DEPTH) && !Effects.can_hold(Type{Vector{Float64}}, held, Effects.HOLD_DEPTH)
    # Open-length tuple holds what its element type holds.
    @test Effects.can_hold(Tuple{Vararg{Vector{Float64}}}, held, Effects.HOLD_DEPTH) && !Effects.can_hold(Tuple{Vararg{Int}}, held, Effects.HOLD_DEPTH)
    # Past depth limit, holder can hold anything.
    @test Effects.can_hold(Tuple{Tuple{Tuple{Tuple{String}}}}, held, Effects.HOLD_DEPTH)
end

include(joinpath(@__DIR__, "ui", "unwritten-element", "positive", "src", "UnwrittenElementPositive.jl"))

@testset "unwritten-element fixtures misbehave at runtime" begin
    @test_throws UndefRefError UnwrittenElementPositive.second_name(2)
    # Fill value counts as data in whole read.
    @test UnwrittenElementPositive.half_filled() == 3.0
end

"""Reference type whose promotion with `Int` throws."""
mutable struct Unpromotable end
Base.promote_rule(::Type{Unpromotable}, ::Type{Int}) = error("no promotion")

@testset "concatenation slot reads match Julia" begin
    # Operand at `unset` has unset slots; others are full, so only its slots can throw.
    unset(type::Type, shape::Tuple)::Array = Array{type}(undef, shape...)
    full(type::Type, shape::Tuple)::Array = fill!(Array{type}(undef, shape...), type === Int ? 1 : "z")
    cases = [
        (vcat, [(String, (2,)), (String, (2,))], 1), (vcat, [(String, (2,)), (String, (2,))], 2), (vcat, [(Any, (2,)), (String, (2,))], 1),
        (vcat, [(String, (2,)), (Any, (2,))], 1), (vcat, [(Any, (2,)), (String, (2,))], 2), (vcat, [(String, (2,)), "x"], 1),
        (vcat, [(String, (2,)), 1], 1), (vcat, [(Any, (2,)), 1], 1), (vcat, [(String, (2,)), SubString("a")], 1),
        (vcat, [(String, (2, 2)), (String, (2, 2))], 1), (vcat, [(String, (2, 2))], 1), (vcat, [(String, (2, 2, 2)), (String, (2, 2, 2))], 1),
        (vcat, [(String, (2,)), (Int, (2,))], 1), (hcat, [(String, (2,)), (String, (2,))], 1), (hcat, [(String, (2,))], 1),
        (hcat, [(String, (2, 2)), (String, (2, 2))], 1), (hcat, [(String, (2, 2)), (String, (2,))], 2), (hcat, [(Any, (2,)), (String, (2,))], 1),
        (hcat, [(String, (2, 2)), (Any, (2, 2))], 1), (hcat, [(String, (2, 2)), (Int, (2, 2))], 1), (hcat, [(String, (2,)), (Any, (2, 2))], 1),
        (hcat, [(String, (2, 2, 2)), (String, (2, 2, 2))], 1), (vcat, [(String, (2, 2)), (Any, (2, 2))], 1), (hcat, [(Any, (2, 2, 2)), (String, (2, 2, 2))], 1),
    ]
    for (callee, specs, position) in cases
        operands = Any[spec isa Tuple ? (index == position ? unset(spec...) : full(spec...)) : spec for (index, spec) in enumerate(specs)]
        throws = try
            callee(operands...)
            false
        catch error
            error isa UndefRefError || rethrow()
            true
        end
        # `vcat` of vectors that converts slots reads them; model leaves promotion out, so it misses that read.
        vectors = all(operand -> !(operand isa AbstractArray) || ndims(operand) == 1, operands)
        converts = callee === vcat && vectors && !allequal(operand isa AbstractArray ? eltype(operand) : typeof(operand) for operand in operands)
        @test Effects.reads_slots(callee, Any[typeof(operand) for operand in operands], typeof(operands[position])) == (throws && !converts)
    end
    # Scalar of abstract type can promote either way: no read.
    @test !Effects.reads_slots(vcat, Any[Vector{String}, Any], Vector{String})
    # Package `promote_rule` that throws never runs.
    @test !Effects.reads_slots(vcat, Any[Vector{Unpromotable}, Int], Vector{Unpromotable})
end
