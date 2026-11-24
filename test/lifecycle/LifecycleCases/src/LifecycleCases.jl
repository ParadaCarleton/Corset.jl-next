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

# Event kinds.
shape_only(x::Vector{Float64}) = (a = similar(x); length(a) + size(a, 1))
viewed() = (a = zeros(4); view(a, 1:2) .= 1.0; sum(a))
resized() = (a = zeros(0); push!(a, 1.0); a)
stored(x::Vector{Vector{Float64}}) = (a = zeros(2); push!(x, a); nothing)
copied_into(b::Vector{Float64}) = (a = ones(2); copyto!(b, a); nothing)
filled_whole() = (a = Vector{Float64}(undef, 3); fill!(a, 0.0); sum(a))
unknown_write(x::Vector{Float64}) = (a = copy(x); sort!(a); a[1])
joined(flag::Bool) = (a = flag ? zeros(2) : ones(2); sum(a))
captured(x::Vector{Float64}) = (a = zeros(2); map(y -> y + a[1], x))
iterated() = (a = ones(2); s = 0.0; for y in a; s += y; end; s)

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

end
