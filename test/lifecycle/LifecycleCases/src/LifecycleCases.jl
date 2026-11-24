# runic: off
"""Fixture package of `lifecycle` stage: method per allocation kind, event kind, path, fill-loop form and rebind pair."""
module LifecycleCases

# Allocation kinds.
undef_read(n::Int) = (v = Vector{String}(undef, n); v[1] = "a"; length(v[2]))
similar_sum(x::Vector{Float64}) = (a = similar(x); sum(a))
filled_constant() = (z = zeros(3); z[1] = 1.0; sum(z))
broadcast_sum(x::Vector{Float64}) = sum(abs.(x))
collected_sum(xs::Vector{Int}) = sum([x^2 for x in xs])
slice_sum(A::Matrix{Float64}, j::Int) = sum(A[:, j])
copied_head(x::Vector{Float64}) = (c = copy(x); c[1] = 0.0; c)
tuple_size() = (t = zeros((2, 3)); sum(t))

# Package call result is no allocation; package method allocates its own.
helper(x::Vector{Float64}) = x .+ 1.0
from_helper(x::Vector{Float64}) = (h = helper(x); sum(h))

# Generated method allocates: blind spot, no array.
@generated generated_sum(x::Vector{Float64}) = :(a = zeros(2); sum(a) + sum(x))

# Event kinds.
shape_only(x::Vector{Float64}) = (a = similar(x); length(a) + size(a, 1))
viewed() = (a = zeros(4); view(a, 1:2) .= 1.0; sum(a))
resized() = (a = zeros(0); push!(a, 1.0); a)
stored(x::Vector{Vector{Float64}}) = (a = zeros(2); push!(x, a); nothing)
copied_into(b::Vector{Float64}) = (a = ones(2); copyto!(b, a); nothing)
keyword_sum(x::Vector{Float64}) = sum(abs.(x); init = 0.0)
concatenated(x::Vector{Vector{Float64}}) = (glue = vcat; reduce(glue, map(reverse, x)))
filled_whole() = (a = Vector{Float64}(undef, 3); fill!(a, 0.0); sum(a))
unknown_write(x::Vector{Float64}) = (a = copy(x); sort!(a); a[1])
joined(flag::Bool) = (a = flag ? zeros(2) : ones(2); sum(a))
captured(x::Vector{Float64}) = (a = zeros(2); map(y -> y + a[1], x))
iterated() = (a = ones(2); s = 0.0; for y in a; s += y; end; s)
# Identical allocations on one line stay two arrays.
twins() = (a = Vector{Float64}(undef, 2); b = Vector{Float64}(undef, 2); fill!(a, 1.0); sum(b))

# Package `!` call can write operands after first one.
struct Scale; factor::Float64; end
(scale::Scale)(x::Float64) = scale.factor * x
scaled!(scale::Scale, r::Vector{Float64}, x::Vector{Float64}) = (r .= scale.(x); r)
functor_first(x::Vector{Float64}) = (r = similar(x); scaled!(Scale(2.0), r, x); sum(r))
both_filled!(a::Vector{Float64}, b::Vector{Float64}) = (fill!(a, 1.0); fill!(b, 2.0); nothing)
function second_output()
    a = Vector{Float64}(undef, 2)
    b = Vector{Float64}(undef, 3)
    both_filled!(a, b)
    return sum(b)
end

# Library `!` call writes subject after functors.
struct Add end
(::Add)(x::Float64, y::Float64) = x + y
mapped_functor(x::Vector{Float64}) = (r = similar(x); map!(Scale(2.0), r, x); sum(r))
reduced_functors(x::Vector{Float64}) = (r = zeros(1); Base.mapreducedim!(Scale(2.0), Add(), r, x); sum(r))

# Prefix writes cover whole array only when source has same extent; array as own source is read first.
prefix_copy(n::Int) = (a = Vector{String}(undef, n); copyto!(a, ["x"]); a)
source_copy(x::Vector{String}) = (a = similar(x); copyto!(a, x); a)
counted_map(x::Vector{String}) = (a = Vector{String}(undef, length(x)); map!(uppercase, a, x); a)
self_map(n::Int) = (a = Vector{String}(undef, n); map!(identity, a, a); a)
self_fill() = (a = Vector{Any}(undef, 2); fill!(a, a); a)
shrunk_copy(x::Vector{String}) = (a = similar(x); pop!(x); copyto!(a, x); a)
sorted(n::Int) = (a = Vector{String}(undef, n); sort!(a); a)
mapped_in_place(n::Int) = (a = Vector{String}(undef, n); map!(uppercase, a); a)

# Paths.
branch_write(flag::Bool) = (a = zeros(2); flag && (a[1] = 1.0); sum(a))
guarded_read(n::Int) = (a = Vector{Float64}(undef, n); n > 0 || throw(ArgumentError("n")); sum(a))
loop_read(n::Int) = (a = zeros(2); s = 0.0; for _ in 1:n; s += sum(a); end; s)

# Fill loops: every element written; runtime test checks `isassigned`.
fill_each(x::Vector{String}) = (a = similar(x); for i in eachindex(a); a[i] = x[i]; end; a)
fill_source(x::AbstractVector{String}) = (a = similar(x); for i in eachindex(x); a[i] = x[i]; end; a)
fill_extent(n::Int) = (a = Vector{String}(undef, n); for i in 1:n; a[i] = string(i); end; a)
fill_counted(x::Vector{String}) = (a = Vector{String}(undef, length(x)); for i in 1:length(a); a[i] = x[i]; end; a)
fill_cartesian(A::Matrix{String}) = (B = similar(A); for i in CartesianIndices(B); B[i] = A[i]; end; B)
shrunk_fill(x::Vector{String}) = (a = similar(x); pop!(x); for i in eachindex(x); a[i] = x[i]; end; a)

# Loops that can skip elements: no fill loop.
partial_fill(n::Int) = (a = Vector{String}(undef, n); for i in 2:n; a[i] = string(i); end; a)
break_fill(x::Vector{String}) = (a = similar(x); for i in eachindex(a); isempty(x[i]) && break; a[i] = x[i]; end; a)
branch_fill(x::Vector{String}) = (a = similar(x); for i in eachindex(a); isempty(x[i]) || (a[i] = x[i]); end; a)

# Rebind pairs: broadcast in loop replaces array allocated before loop.
rebound(x::Vector{Float64}, n::Int) = (y = zeros(length(x)); for _ in 1:n; y = y .+ x; end; y)
scaled(x::Vector{Float64}, n::Int) = (y = copy(x); for _ in 1:n; y = 2 .* y; end; y)
shared(n::Int) = (y = ones(2); kept = Vector{Float64}[]; for _ in 1:n; y = 2 .* y; push!(kept, y); end; kept)

end
