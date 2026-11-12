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
memo(x::Int) = get!(CACHE, x) do; x^2 end
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
]

"""Strongest write certainty on parameter `j` (1 is the function)."""
argwrite(s::Summary, j::Int)::Certainty = max(s.params[j].top, s.params[j].inner)
gwrite(s::Summary, name::Symbol)::Certainty = maximum((c for (k, c) in s.globals if k.name === name); init = NONE)

index_constants!()
eng = Engine()
sums = Dict{Symbol, Summary}()
for (name, types) in TARGETS
    mi = Base.method_instance(getfield(Fx, name), types)
    sums[name] = on_big_stack(() -> summary!(eng, mi))
    s = sums[name]
    println(rpad(name, 18), " args=", [argwrite(s, j) for j in 2:length(s.params)],
        " globals=", Dict(string(k.mod, ".", k.name) => c for (k, c) in s.globals), " opaque=", s.opaque)
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
    @test gwrite(sums[:nonconst_global], :counter) == POSSIBLE  # untyped global: dynamic setindex!
    @test gwrite(sums[:typed_global], :typed_counter) == DEFINITE
    @test gwrite(sums[:memo], :CACHE) == DEFINITE        # exempted later by memo rule
    @test argwrite(sums[:unknown_callee], 2) == POSSIBLE
    @test argwrite(sums[:iobuffer_write], 2) == DEFINITE  # exempted later by IO rule
    @test argwrite(sums[:rng_draw], 2) == DEFINITE        # exempted later by RNG rule
end
println("instances analyzed: ", eng.stats.instances, "  stats: ", eng.stats)
