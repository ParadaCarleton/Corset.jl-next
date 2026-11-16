# Fixtures for spike S5. Run: julia +1.13 --project=. fixtures.jl
include("src/EffectSpike.jl")
using .EffectSpike
using Random: AbstractRNG, Xoshiro
using Test

module Fx
    using Random: AbstractRNG

    struct Wrapper
        v::Vector{Int}
    end

    const CACHE = Dict{Int, Int}()
    const REGISTRY = Int[]
    counter = Ref(0)
    typed_counter::Base.RefValue{Int} = Ref(0)

    alias_view(a::Vector{Int}) = (v = view(a, 1:2); v[1] = 0; nothing)
    @noinline poke!(v::AbstractVector{Int}) = (v[1] = 0; nothing)
    alias_view_call(a::Vector{Int}) = (poke!(view(a, 1:2)); nothing)
    closure_write(a::Vector{Int}) = (c = () -> push!(a, 1); c(); nothing)
    @noinline callit(f::F) where {F} = f()
    closure_noinline(a::Vector{Int}) = (callit(() -> push!(a, 1)); nothing)
    field_write(w::Wrapper) = (w.v[1] = 0; nothing)
    @noinline ping(a::Vector{Int}, n::Int) = n <= 0 ? nothing : pong(a, n - 1)
    @noinline pong(a::Vector{Int}, n::Int) = (a[1] = n; ping(a, n - 1))
    pure_copy(a::Vector{Int}) = (b = copy(a); b[1] = 0; b)
    fresh_wrapper(a::Vector{Int}) = (r = Ref(a); r[] = Int[]; nothing)
    io_write(io::IO, x::Int) = (print(io, x); nothing)
    iobuffer_write(io::IOBuffer, x::Int) = (write(io, x); nothing)
    rng_draw(rng::Xoshiro_) where {Xoshiro_ <: AbstractRNG} = rand(rng)
    global_rng() = rand()
    memo(x::Int) = get!(CACHE, x) do;
        x^2
    end
    register(x::Int) = (push!(REGISTRY, x); nothing)
    getreg() = REGISTRY
    via_result(x::Int) = (push!(getreg(), x); nothing)
    nonconst_global(x::Int) = (counter[] = x; nothing)
    typed_global(x::Int) = (typed_counter[] = x; nothing)
    unknown_callee(x::Vector{Int}, f::Function) = (f(x); nothing)
    reads_only(a::Vector{Int}) = sum(a)
    @noinline wrap_global() = [REGISTRY]
    write_wrapped_global() = (push!(wrap_global()[1], 1); nothing)
    @noinline maybe_alias(x::Vector{Int}, flag::Bool) = flag ? x : copy(x)
    write_maybe(x::Vector{Int}, flag::Bool) = (maybe_alias(x, flag)[1] = 0; nothing)
    lazy_string_read(s::LazyString) = String(s)
    broadcast_fresh(x::Matrix{Float64}) = x .- sum(x; dims = 1)
    store_then_write(x::Vector{Vector{Int}}) = (b = zeros(Int, 1); push!(x, b); b[1] = 5; nothing)
    unknown_tuple(a::Vector{Int}, T::Type) = (T((a,)); nothing)
    @noinline write_first(xs::Vector{Int}...) = (xs[1][1] = 0; nothing)
    write_first_of(a::Vector{Int}, b::Vector{Int}) = (write_first(a, b); nothing)
    @noinline maybe_wrap(a::Vector{Int}, flag::Bool) = flag ? Ref(a) : Ref([0])
    write_wrap(a::Vector{Int}, flag::Bool) = (maybe_wrap(a, flag)[][1] = 0; nothing)
    @noinline va_first(xs::Vector{Int}...) = xs[1]
    write_va(a::Vector{Int}) = (va_first(a)[1] = 0; nothing)
    write_va2(a::Vector{Int}, b::Vector{Int}) = (va_first(a, b)[1] = 0; nothing)
    mutable struct Node
        val::Int
        next::Union{Nothing, Node}
    end
    @noinline function bump(n::Node)
        while n.next !== nothing
            n = n.next
        end
        n.val += 1
        return nothing
    end
    cyclic_wrapped(n::Node) = (bump(Node(0, n)); nothing)
    invoke_write(a::Vector{Int}) = (invoke(push!, Tuple{Vector{Int}, Int}, a, 1); nothing)
    splat_pure(xs::Vector{Float64}) = +(xs...)
    struct Pusher{T}
        v::Vector{T}
        Pusher{T}(v::Vector{T}) where {T} = (push!(v, zero(T)); new{T}(v))
    end
    make_pusher(v::Vector{T}) where {T} = (Pusher{Base.inferencebarrier(T)}(v); nothing)
    @noinline read_all(vs::Vector{Int}...) = (
        n = 0; for v in vs
            n += length(v)
        end; n
    )
    @noinline push_all!(vs::Vector{Int}...) = (
        for v in vs
            push!(v, 1)
        end; nothing
    )
    @noinline push_first!(a::Vector{Int}, ys::Int...) = (push!(a, length(ys)); nothing)
    splat_read(xs::Tuple{Vararg{Vector{Int}}}) = (read_all(xs...); nothing)
    splat_elems(xs::Tuple{Vararg{Vector{Int}}}) = (push_all!(xs...); nothing)
    splat_prefix(a::Vector{Int}, xs::Tuple{Vararg{Int}}) = (push_first!(a, xs...); nothing)
    abstract type Shape end
    struct Sq <: Shape end
    struct Ci <: Shape end
    @noinline stamp!(v::Vector{Int}, ::Sq) = (push!(v, 1); nothing)
    @noinline stamp!(v::Vector{Int}, ::Ci) = (push!(v, 2); nothing)
    @noinline maybe_stamp!(v::Vector{Int}, ::Sq) = (push!(v, 1); nothing)
    @noinline maybe_stamp!(v::Vector{Int}, ::Ci) = nothing
    join_both(v::Vector{Int}, s::Shape) = (stamp!(v, s); nothing)
    join_one(v::Vector{Int}, s::Shape) = (maybe_stamp!(v, s); nothing)
    abstract type Op end
    for i in 1:6
        name = Symbol(:O, i)
        @eval struct $name <: Op end
        @eval @noinline apply_op!(v::Vector{Int}, ::$name) = (push!(v, $i); nothing)
    end
    pkg_join(v::Vector{Int}, o::Op) = (apply_op!(v, Base.inferencebarrier(o)::Op); nothing)
    loop_push(vs::Vector{Vector{Int}}) = (
        for v in vs
            push!(v, 1)
        end; nothing
    )
    tuple_loop(vs::NTuple{3, Vector{Int}}) = (
        for v in vs
            push!(v, 1)
        end; nothing
    )
    dict_loop(d::Dict{Int, Vector{Int}}) = (
        for (k, v) in d
            push!(v, k)
        end; nothing
    )
    mutable struct Link
        data::Any
        next::Union{Nothing, Link}
    end
    mutable struct ListNode{T}
        data::T
        next::ListNode{T}
        ListNode{T}() where {T} = (l = new{T}(); l.next = l; l)
    end
    mutable struct MList{T}
        node::ListNode{T}
    end
    # loop phi over loads from list head: write keeps base of parameter 2 after storing `data`
    walk_set(l::MList{T}, data, n::Int) where {T} = (
        node = l.node; for _ in 1:n
            node = node.next
        end; node.data = convert(T, data); nothing
    )
    dict_store(d::Dict{Int, Vector{Int}}, v::Vector{Int}) = (d[1] = v; nothing)
    dict_get_push(d::Dict{Int, Vector{Int}}) = (push!(d[1], 1); nothing)
    @noinline set_pair!(v::Vector{<:Integer}, iv::Tuple{Vector{<:Integer}, Integer}) = (setindex!(iv..., 1); nothing)
    struct Holder
        f::Any
    end
    const CALLBACKS = Any[]
    @noinline apply_any(@nospecialize(f), x::Vector{Int}) = (f(x); nothing)
    pass_any(f, x::Vector{Int}) = apply_any(f, x)
    use_any(x::Vector{Int}) = apply_any(empty!, x)
    global_any(x::Vector{Int}) = apply_any(CALLBACKS[1], x)
    call_field(h::Holder, x::Vector{Int}) = (h.f(x); nothing)
    call_global(x::Vector{Int}) = (CALLBACKS[1](x); nothing)
    fold_tuple(op, xs::NamedTuple) = Base._foldl_impl(op, 0, xs)
    @noinline generic_len(x) = 0
    @noinline generic_len(x::Vector{Int}) = (push!(x, 1); length(x))
    invoke_open(x::Vector{Int}, y) = invoke(generic_len, Tuple{Core.Typeof(y)}, x)
    invoke_va(x::Vector{Int}, ys...) = invoke(generic_len, Tuple{map(Core.Typeof, ys)...}, x)
    const UNKNOWN_F = Ref{Any}(identity)
    struct Emptier
        Emptier(x::Vector{Int}) = (empty!(x); new())
    end
    @noinline sp_call(::Type{S}, x::Vector{Int}) where {S} = (S(x); nothing)
    sp_relay(::Type{S}, x::Vector{Int}) where {S} = sp_call(S, x)
    @noinline ty_call(@nospecialize(T::Type), x::Vector{Int}) = (T(x); nothing)
    ty_relay(T::Type, x::Vector{Int}) = ty_call(T, x)
    ty_const(x::Vector{Int}) = ty_call(Emptier, x)
    ty_invoke(x::Vector{Int}) = invoke(ty_call, Tuple{Type, Vector{Int}}, Emptier, x)
    struct Box2
        v::Any
    end
    @noinline ty_store(@nospecialize(T::Type), x::Vector{Int}) = Box2(T(x))
    ty_store_invoke(x::Vector{Int}) = invoke(ty_store, Tuple{Type, Vector{Int}}, Emptier, x)
    @noinline ty_either(@nospecialize(T::Type), x::Vector{Int}, flag::Bool) = (T(flag ? x : Int[]); nothing)
    ty_either_invoke(x::Vector{Int}) = invoke(ty_either, Tuple{Type, Vector{Int}, Bool}, Emptier, x, rand(Bool))
    ty_opaque(x::Vector{Int}) = ty_call(Base.inferencebarrier(Emptier)::Type, x)
    sym_of(v::Vector{UInt8}) = ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Int), v, length(v))
    # passing BigFloat to MPFR repairs a stale self-pointer in its limbs: no visible write
    big_print(x::BigFloat) = ccall((:mpfr_asprintf, Base.MPFR.libmpfr), Cint, (Ptr{Ptr{UInt8}}, Ptr{UInt8}, Ref{BigFloat}...), Ref{Ptr{UInt8}}(), "%Re", x)
    big_set(x::BigFloat) = ccall((:mpfr_set_si, Base.MPFR.libmpfr), Int32, (Ref{BigFloat}, Clong, Base.MPFR.MPFRRoundingMode), x, 1, Base.MPFR.MPFRRoundNearest)
    # author asserts no side effect; analysis alone sees unknown callee on argument
    Base.@assume_effects :effect_free asserted_pure(x::Vector{Int}) = (Base.inferencebarrier(sum)(x); nothing)
    unasserted(x::Vector{Int}) = (Base.inferencebarrier(sum)(x); nothing)
    @noinline ty_keep(@nospecialize(T::Type), x::Vector{Int}, keep::Vector{Vector{Int}}) = (T(x); push!(keep, x); nothing)
    ty_keep_invoke(x::Vector{Int}, keep::Vector{Vector{Int}}) = invoke(ty_keep, Tuple{Type, Vector{Int}, Vector{Vector{Int}}}, Emptier, x, keep)
    @noinline ty_either_relay(@nospecialize(T::Type), x::Vector{Int}, flag::Bool) = ty_either(T, x, flag)
    ty_either_relay_invoke(x::Vector{Int}) = invoke(ty_either_relay, Tuple{Type, Vector{Int}, Bool}, Emptier, x, rand(Bool))
    u64_pure(x) = UInt64(x)
    vec_push_elem(v::Vector{Vector{Int}}) = (push!(v[1], 1); nothing)
    share_ref(v::Vector{Int}) = (w = Int[]; setfield!(w, :ref, getfield(v, :ref)); w[1] = 0; nothing)
    mutable struct Holder3
        v::Vector{Int}
    end
    prop_store(h::Holder3, v::Vector{Int}) = (h.v = v; push!(h.v, 1); nothing)
    @noinline fill_one!(x::Vector{Int}) = (fill!(x, 1); nothing)
    @noinline zero_one!(x::Vector{Int}) = (x[1] = 0; nothing)
    pick_op(flag::Bool) = flag ? fill_one! : zero_one!
    split_union(x::Vector{Int}, flag::Bool) = (pick_op(flag)(x); nothing)
    @noinline two!(x::AbstractVector{Int}, y::AbstractVector{Int}) = (x[1] = y[1]; nothing)
    pick_copy(flag::Bool) = flag ? copyto! : two!
    split_many(x::AbstractVector{Int}, y::AbstractVector{Int}, flag::Bool) = (pick_copy(flag)(x, y); nothing)
    range_copy(a::AbstractVector{Vector{Int}}) = (b = a[1:2]; push!(b, Int[]); nothing)
    range_elem(a::AbstractVector{Vector{Int}}) = (b = a[1:2]; push!(b[1], 1); nothing)
    @noinline cyc_w(x::Vector{Int}, k::Int) = (push!(x, k); nothing)
    @noinline cyc_w(x::Vector{Int}, k::Float64) = cyc_w(x, Base.inferencebarrier(1)::Real)
    @noinline cyc_u(x::Vector{Int}, k::Int) = (UNKNOWN_F[](x); nothing)
    @noinline cyc_u(x::Vector{Int}, k::Float64) = cyc_u(x, Base.inferencebarrier(1)::Real)
    ptr_store(buf::AbstractVector{UInt8}) = (GC.@preserve buf unsafe_store!(pointer(buf), 0x01); nothing)
    ptr_load(buf::AbstractVector{UInt8}) = GC.@preserve buf unsafe_load(pointer(buf))
    @noinline copy_elems!(dst::Vector{Vector{Int}}, src::Vector{Vector{Int}}) = (
        for i in eachindex(src)
            dst[i] = src[i]
        end; nothing
    )
    copy_then_push(dst::Vector{Vector{Int}}, src::Vector{Vector{Int}}) = (copy_elems!(dst, src); push!(dst[1], 1); nothing)
    memory_from(x::Vector{Vector{Int}}) = Memory{Vector{Int}}(x)
    memory_from_any(x::AbstractVector{Vector{Int}}) = Memory{Vector{Int}}(x)
    unalias_any(dest::AbstractArray, a::AbstractArray) = Base.unalias(dest, a)
    copyto_push(dst::AbstractVector{Vector{Int}}, src::AbstractVector{Vector{Int}}) = (copyto!(dst, src); push!(dst[1], 1); nothing)
    big_cmp(x::BigInt) = x > 0
    big_sub(x::BigInt) = x - 1
    @noinline set_all!(d::Dict{Int, Int}, kv...) = (setindex!(d, kv...); nothing)
    assert_push(xs::Vector{Any}) = (push!(xs[1]::Vector{Int}, 1); nothing)
    splat_tuple_read(a::Vector{Int}, xs::Tuple{Vararg{Vector{Int}}}) = length(tuple(a, xs...))
    splat_tuple_write(a::Vector{Int}, xs::Tuple{Vararg{Vector{Int}}}) = (t = tuple(a, xs...); push!(t[1], 1); nothing)
    dict_read_store(d::Dict{Int, Vector{Int}}, v::Vector{Int}) = (x = d[1]; d[2] = v; length(x))
    @noinline bump_inner!(vs::Vector{Vector{Int}}) = (push!(vs[1], 1); nothing)
    deep_call(r::Base.RefValue{Vector{Vector{Int}}}) = (bump_inner!(r[]); nothing)
    # loop phi joins second parameter: base unknown
    walk_either(l::Link, m::Link, n::Int) = (
        node = l; for _ in 1:n
            node = m
        end; node.data = 0; nothing
    )
end

const TARGETS = [
    (:alias_view, (Vector{Int},)), (:alias_view_call, (Vector{Int},)), (:closure_write, (Vector{Int},)),
    (:closure_noinline, (Vector{Int},)), (:field_write, (Fx.Wrapper,)), (:ping, (Vector{Int}, Int)),
    (:pong, (Vector{Int}, Int)), (:pure_copy, (Vector{Int},)), (:fresh_wrapper, (Vector{Int},)),
    (:io_write, (IO, Int)), (:iobuffer_write, (IOBuffer, Int)), (:rng_draw, (Xoshiro,)), (:global_rng, ()),
    (:memo, (Int,)), (:register, (Int,)), (:via_result, (Int,)), (:nonconst_global, (Int,)), (:typed_global, (Int,)),
    (:unknown_callee, (Vector{Int}, Function)), (:reads_only, (Vector{Int},)), (:broadcast_fresh, (Matrix{Float64},)),
    (:store_then_write, (Vector{Vector{Int}},)), (:write_wrapped_global, ()),
    (:write_maybe, (Vector{Int}, Bool)), (:lazy_string_read, (LazyString,)),
    (:unknown_tuple, (Vector{Int}, Type)), (:write_first_of, (Vector{Int}, Vector{Int})),
    (:write_wrap, (Vector{Int}, Bool)), (:write_va, (Vector{Int},)), (:write_va2, (Vector{Int}, Vector{Int})),
    (:cyclic_wrapped, (Fx.Node,)), (:invoke_write, (Vector{Int},)), (:splat_pure, (Vector{Float64},)),
    (:make_pusher, (Vector{Int},)), (:splat_read, (Tuple{Vararg{Vector{Int}}},)), (:splat_elems, (Tuple{Vararg{Vector{Int}}},)),
    (:splat_prefix, (Vector{Int}, Tuple{Vararg{Int}})), (:join_both, (Vector{Int}, Fx.Shape)), (:join_one, (Vector{Int}, Fx.Shape)),
    (:pkg_join, (Vector{Int}, Fx.Op)),
    (:walk_set, (Fx.MList{Int}, Any, Int)), (:dict_store, (Dict{Int, Vector{Int}}, Vector{Int})),
    (:deep_call, (Base.RefValue{Vector{Vector{Int}}},)), (:dict_get_push, (Dict{Int, Vector{Int}},)),
    (:dict_read_store, (Dict{Int, Vector{Int}}, Vector{Int})), (:assert_push, (Vector{Any},)), (:big_cmp, (BigInt,)), (:copy_then_push, (Vector{Vector{Int}}, Vector{Vector{Int}})), (:memory_from, (Vector{Vector{Int}},)),
    (:memory_from_any, (AbstractVector{Vector{Int}},)), (:unalias_any, (AbstractArray, AbstractArray)), (:copyto_push, (AbstractVector{Vector{Int}}, AbstractVector{Vector{Int}})), (:ptr_store, (AbstractVector{UInt8},)), (:ptr_load, (AbstractVector{UInt8},)), (:cyc_w, (Vector{Int}, Float64)), (:cyc_u, (Vector{Int}, Float64)), (:apply_any, (Any, Vector{Int})), (:pass_any, (Any, Vector{Int})),
    (:use_any, (Vector{Int},)), (:global_any, (Vector{Int},)), (:call_field, (Fx.Holder, Vector{Int})), (:call_global, (Vector{Int},)),
    (:fold_tuple, (Any, NamedTuple)), (:invoke_open, (Vector{Int}, Any)), (:invoke_va, (Vector{Int}, Vararg{Any})), (:set_pair!, (Vector{<:Integer}, Tuple{Vector{<:Integer}, Integer})), (:big_sub, (BigInt,)),
    (:set_all!, (Dict{Int, Int}, Vararg{Any})),
    (:sp_call, :declared), (:sp_relay, :declared), (:ty_call, (Type, Vector{Int})), (:ty_relay, (Type, Vector{Int})), (:ty_const, (Vector{Int},)), (:ty_invoke, (Vector{Int},)), (:ty_store, (Type, Vector{Int})), (:ty_store_invoke, (Vector{Int},)), (:ty_either, (Type, Vector{Int}, Bool)), (:ty_either_invoke, (Vector{Int},)), (:asserted_pure, (Vector{Int},)), (:unasserted, (Vector{Int},)), (:sym_of, (Vector{UInt8},)), (:big_print, (BigFloat,)), (:big_set, (BigFloat,)), (:ty_keep, (Type, Vector{Int}, Vector{Vector{Int}})), (:ty_keep_invoke, (Vector{Int}, Vector{Vector{Int}})), (:ty_either_relay, (Type, Vector{Int}, Bool)), (:ty_either_relay_invoke, (Vector{Int},)),
    (:ty_opaque, (Vector{Int},)), (:u64_pure, (Any,)), (:range_copy, (AbstractVector{Vector{Int}},)), (:split_union, (Vector{Int}, Bool)), (:split_many, (AbstractVector{Int}, AbstractVector{Int}, Bool)), (:vec_push_elem, (Vector{Vector{Int}},)), (:share_ref, (Vector{Int},)), (:prop_store, (Fx.Holder3, Vector{Int})), (:range_elem, (AbstractVector{Vector{Int}},)),
    (:splat_tuple_read, (Vector{Int}, Tuple{Vararg{Vector{Int}}})), (:splat_tuple_write, (Vector{Int}, Tuple{Vararg{Vector{Int}}})), (:walk_either, (Fx.Link, Fx.Link, Int)), (:loop_push, (Vector{Vector{Int}},)), (:tuple_loop, (NTuple{3, Vector{Int}},)), (:dict_loop, (Dict{Int, Vector{Int}},)),
]

"""Strongest write certainty on parameter `j` (1 is the function)."""
argwrite(s::Summary, j::Int)::Certainty = written(s.params[j])
gwrite(s::Summary, name::Symbol)::Certainty = maximum((c for (k, c) in s.globals if k.name === name); init = NONE)

index_constants!()
# fixture module lives in Main: its methods count as package methods
get(ENV, "S5_PKGJOIN", "1") == "1" && push!(PACKAGE_ROOTS, Main)
eng = Engine()
sums = Dict{Symbol, Summary}()
for (name, types) in TARGETS
    mi = types === :declared ? declared_instance(only(methods(getfield(Fx, name)))) : Base.method_instance(getfield(Fx, name), types)
    sums[name] = on_big_stack(() -> summary!(eng, mi))
    s = sums[name]
    println(
        rpad(name, 18), " args=", [argwrite(s, j) for j in 2:length(s.params)],
        " globals=", Dict(string(k.mod, ".", k.name) => c for (k, c) in s.globals), " opaque=", s.opaque
    )
end

@testset "S5 fixtures" begin
    @test argwrite(sums[:alias_view], 2) == DEFINITE
    @test argwrite(sums[:alias_view_call], 2) == DEFINITE
    @test argwrite(sums[:closure_write], 2) == DEFINITE
    @test argwrite(sums[:closure_noinline], 2) >= POSSIBLE
    @test argwrite(sums[:field_write], 2) == DEFINITE
    @test argwrite(sums[:ping], 2) == DEFINITE
    @test argwrite(sums[:pong], 2) == DEFINITE
    @test argwrite(sums[:pure_copy], 2) == NONE
    @test argwrite(sums[:fresh_wrapper], 2) == NONE
    @test argwrite(sums[:reads_only], 2) == NONE
    @test argwrite(sums[:broadcast_fresh], 2) == NONE    # unalias phi(x, copy(x)) must not leak copy write
    @test argwrite(sums[:store_then_write], 2) == DEFINITE
    @test argwrite(sums[:write_maybe], 2) == POSSIBLE      # possible alias must not become definite
    @test argwrite(sums[:lazy_string_read], 2) <= POSSIBLE # LazyString cache is lazy init
    @test gwrite(sums[:write_wrapped_global], :REGISTRY) >= POSSIBLE  # fresh result holding global
    @test gwrite(sums[:register], :REGISTRY) == DEFINITE
    @test gwrite(sums[:via_result], :REGISTRY) == DEFINITE
    @test gwrite(sums[:nonconst_global], :counter) == (EffectSpike.CONTRACTS_ON ? DEFINITE : POSSIBLE)  # untyped global: setindex! contract writes collection
    @test gwrite(sums[:typed_global], :typed_counter) == DEFINITE
    @test gwrite(sums[:memo], :CACHE) == DEFINITE        # exempted later by memo rule
    @test argwrite(sums[:unknown_callee], 2) == NONE && haskey(sums[:unknown_callee].calls, (3, 0))  # design step 2
    @test argwrite(sums[:iobuffer_write], 2) == DEFINITE  # exempted later by IO rule
    @test argwrite(sums[:rng_draw], 2) == DEFINITE        # exempted later by RNG rule
    @test argwrite(sums[:unknown_tuple], 2) == POSSIBLE   # fresh tuple holding argument reaches unknown callee
    @test argwrite(sums[:write_va], 2) == DEFINITE        # single vararg operand maps exactly
    @test argwrite(sums[:write_va2], 2) == POSSIBLE       # shared vararg summary
    @test argwrite(sums[:write_va2], 3) == POSSIBLE
    @test argwrite(sums[:write_first_of], 3) == POSSIBLE  # shared vararg: write to one element is possible for each
    @test argwrite(sums[:write_wrap], 2) == POSSIBLE      # result holds argument or fresh array
    @test argwrite(sums[:cyclic_wrapped], 2) >= POSSIBLE  # cyclic class behind fresh wrapper
    @test argwrite(sums[:invoke_write], 2) == DEFINITE    # invoke resolves to selected method
    @test argwrite(sums[:splat_pure], 2) == NONE  # pure contract, or closed-world join, through splat
    @test sums[:splat_pure].assumed  # contract or closed-world join
    @test argwrite(sums[:make_pusher], 2) == DEFINITE     # constructor of parametric type: join over its methods
    @test sums[:make_pusher].assumed
    @test argwrite(sums[:splat_read], 2) == NONE          # unknown-length splat into reader
    @test argwrite(sums[:splat_elems], 2) == POSSIBLE     # writes elements; tuple may be empty
    @test argwrite(sums[:splat_prefix], 2) == DEFINITE    # fixed prefix operand keeps definite write
    @test argwrite(sums[:join_both], 2) == DEFINITE       # every candidate writes
    @test argwrite(sums[:join_one], 2) == POSSIBLE        # one candidate writes
    @test argwrite(sums[:dict_store], 2) == DEFINITE     # Dict storage written
    @test argwrite(sums[:dict_store], 3) == (EffectSpike.CONTRACTS_ON ? NONE : POSSIBLE)  # rehash! stores memory through `setproperty!`: convert contract
    @test sums[:dict_get_push].params[2].inner == DEFINITE  # Dict value sits at depth 1: memory fields are Dict itself
    @test sums[:dict_get_push].params[2].deep == NONE
    @test argwrite(sums[:dict_read_store], 3) == (EffectSpike.CONTRACTS_ON ? NONE : POSSIBLE)  # rehash! setproperty! needs convert contract
    @test argwrite(sums[:set_pair!], 3) != NONE            # fixed-length splat with abstract elements
    @test !startswith(sums[:set_pair!].blames[3], "apply_shape")
    @test !EffectSpike.fixed_length(Tuple{Vararg{Int, TypeVar(:N)}})  # free-length vararg is no fixed shape
    @test EffectSpike.fixed_length(Tuple{}) && !EffectSpike.fixed_length(Tuple{Int, Vararg{Any}})
    # callable from parameter: call record, no write; caller substitutes or demotes
    @test argwrite(sums[:apply_any], 3) == NONE && length(sums[:apply_any].calls) == 1
    @test sums[:apply_any].calls == EffectSpike.Calls((2, 0) => Dict(3 => 0))
    @test argwrite(sums[:pass_any], 3) == NONE && length(sums[:pass_any].calls) == 1
    @test argwrite(sums[:use_any], 2) == DEFINITE  # inference specializes callee on `empty!`
    @test argwrite(sums[:global_any], 2) == POSSIBLE && startswith(sums[:global_any].blames[2], "callback")
    @test argwrite(sums[:call_field], 3) == NONE && only(keys(sums[:call_field].calls)) == (2, 1)
    @test argwrite(sums[:call_global], 2) == POSSIBLE && isempty(sums[:call_global].calls)
    @test !isempty(sums[:fold_tuple].calls)  # open invoke and NamedTuple splat resolve
    @test argwrite(sums[:fold_tuple], 3) == (EffectSpike.CONTRACTS_ON ? NONE : POSSIBLE)  # open `iterate` needs contract
    @test argwrite(sums[:invoke_open], 2) == POSSIBLE  # T may select either method: join of write and no write
    @test startswith(sums[:invoke_open].blames[2], "join")
    @test argwrite(sums[:invoke_va], 2) == POSSIBLE  # type tuple of unknown length
    # callee is type value caller chooses: record; caller maps it to own static parameter or resolves it
    @test argwrite(sums[:sp_call], 3) == NONE && sums[:sp_call].type_calls == EffectSpike.TypeCalls([((:sparam, 1), [3])])
    @test argwrite(sums[:sp_relay], 3) == NONE && sums[:sp_relay].type_calls == EffectSpike.TypeCalls([((:sparam, 1), [3])])
    @test argwrite(sums[:ty_call], 3) == NONE && sums[:ty_call].type_calls == EffectSpike.TypeCalls([((:param, 2), [3])])
    @test argwrite(sums[:ty_relay], 3) == NONE && sums[:ty_relay].type_calls == EffectSpike.TypeCalls([((:param, 2), [3])])
    @test argwrite(sums[:ty_const], 2) == DEFINITE  # inference specializes callee on `Type{Emptier}`
    @test argwrite(sums[:ty_store], 3) == NONE && !isempty(sums[:ty_store].type_calls)  # result stored in fresh object
    @test argwrite(sums[:ty_store_invoke], 2) != NONE
    @test argwrite(sums[:ty_either], 3) == NONE && !isempty(sums[:ty_either].type_calls)
    @test argwrite(sums[:ty_either_invoke], 2) == POSSIBLE  # operand may be fresh vector
    @test argwrite(sums[:sym_of], 2) == NONE  # `jl_symbol_n` reads bytes
    @test argwrite(sums[:big_print], 2) == NONE && argwrite(sums[:big_set], 2) == DEFINITE  # MPFR self-pointer repair
    @test argwrite(sums[:unasserted], 2) == POSSIBLE
    @test argwrite(sums[:asserted_pure], 2) == NONE  # compiler effects: `@assume_effects :effect_free`
    # parameter operand stays exact after later store merges its class
    @test sums[:ty_keep].type_calls == EffectSpike.TypeCalls([((:param, 2), [3])]) && argwrite(sums[:ty_keep_invoke], 2) == DEFINITE
    # relayed record keeps relaxed position
    @test all(((o, pos),) -> pos == [-3], sums[:ty_either_relay].type_calls) && argwrite(sums[:ty_either_relay_invoke], 2) == POSSIBLE
    @test argwrite(sums[:ty_invoke], 2) == DEFINITE  # abstract instance: caller resolves record to `Emptier` constructor
    @test argwrite(sums[:ty_opaque], 2) == POSSIBLE && startswith(sums[:ty_opaque].blames[2], "typecall")
    @test argwrite(sums[:range_copy], 2) == POSSIBLE  # copy shares elements; `push!` contract writes every depth
    @test argwrite(sums[:range_elem], 2) != NONE  # copy shares elements
    @test argwrite(sums[:split_union], 2) == DEFINITE  # inference splits union callee
    @test argwrite(sums[:split_many], 2) == (EffectSpike.CONTRACTS_ON ? DEFINITE : POSSIBLE)  # engine splits: `copyto!` contract and `two!`
    @test argwrite(sums[:split_many], 3) == POSSIBLE  # `copyto!` contract writes every depth of its destination, which may share elements
    @test EffectSpike.storage_field(Dict{Int, Int}, :keys) === true && EffectSpike.storage_field(Base.RefValue{Memory{Int}}, :x) === false
    @test EffectSpike.has_storage(Any) === nothing && EffectSpike.storage_field(Vector{Int}, :nofield) === nothing
    # memory fields are their owner: elements one level below vector, as contracts put them
    @test sums[:vec_push_elem].params[2].inner == DEFINITE && sums[:vec_push_elem].params[2].top == NONE
    @test argwrite(sums[:share_ref], 2) != NONE  # vectors sharing memory are one class
    @test argwrite(sums[:prop_store], 3) != NONE && sums[:prop_store].params[2].top == DEFINITE  # default property methods are field access
    @test argwrite(sums[:u64_pure], 2) == (EffectSpike.CONTRACTS_ON ? NONE : POSSIBLE)  # bits number constructor converts
    # join whose candidate is its own SCC: greatest fixpoint of agreement; leaf uncertainty never promotes
    @test argwrite(sums[:cyc_w], 2) == (EffectSpike.MUST_PASS ? DEFINITE : POSSIBLE)
    @test argwrite(sums[:cyc_u], 2) == POSSIBLE
    @test argwrite(sums[:ptr_store], 2) == POSSIBLE  # contract alias is possible: later method can break it
    @test argwrite(sums[:ptr_load], 2) == (EffectSpike.CONTRACTS_ON ? NONE : POSSIBLE)  # pointer contract writes nothing
    @test argwrite(sums[:copy_then_push], 3) != NONE  # dst elements are src elements after copy
    @test argwrite(sums[:memory_from], 2) == NONE     # copy reads source elements
    @test argwrite(sums[:memory_from_any], 2) == POSSIBLE  # imprecise: generic copyto! candidate stores src in dest content
    @test argwrite(sums[:copyto_push], 3) != NONE     # shared elements reach source
    @test isempty(sums[:unalias_any].merges)  # branch condition from unknown call merges nothing
    @test argwrite(sums[:big_cmp], 2) == NONE              # GMP comparison reads
    @test argwrite(sums[:big_sub], 2) == NONE              # GMP writes output operand only
    @test !startswith(sums[:set_all!].blames[2], "apply_")  # unknown-length splat resolves to candidate join
    @test sums[:dict_store].params[2].overlap == NONE      # returned parameter is `same`, never overlap
    @test sums[:assert_push].params[2].inner == DEFINITE   # typeassert result is its operand
    @test argwrite(sums[:splat_tuple_read], 2) == NONE    # splat into tuple builtin builds fresh tuple
    @test argwrite(sums[:splat_tuple_read], 3) == NONE
    @test argwrite(sums[:splat_tuple_write], 2) == POSSIBLE  # element of merged tuple content
    @test argwrite(sums[:splat_tuple_write], 3) == POSSIBLE      # reading other value keeps stored value unwritten
    @test sums[:deep_call].params[2].deep == DEFINITE    # callee writes depth 1 of its argument: depth 2 here
    @test sums[:deep_call].params[2].top == NONE
    @test argwrite(sums[:walk_set], 2) == DEFINITE       # loop phi keeps base of list head
    @test argwrite(sums[:walk_either], 2) == POSSIBLE    # back-edge from other parameter: no base
    @test argwrite(sums[:walk_either], 3) == POSSIBLE
    @test argwrite(sums[:loop_push], 2) == DEFINITE      # iterate result tuple holds element
    @test argwrite(sums[:tuple_loop], 2) == DEFINITE
    @test argwrite(sums[:dict_loop], 2) == DEFINITE
    @test argwrite(sums[:pkg_join], 2) == (get(ENV, "S5_PKGJOIN", "1") == "1" ? DEFINITE : POSSIBLE)  # package closed world
end
println("instances analyzed: ", eng.stats.instances, "  stats: ", eng.stats)
