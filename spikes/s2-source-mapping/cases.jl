"""Small methods, one per mapping case. `measure.jl` includes this file into module `Cases`."""
module Cases

using Base: @kwdef

plain_call(x::Float64) = sqrt(abs(x)) + 1

function broadcast_call(xs::Vector{Float64})
    ys = xs .* 2 .+ 1
    return sum(ys)
end

function keyword_method(x::Float64; scale::Float64 = 2.0)
    return x * scale
end

function do_block(xs::Vector{Float64})
    return map(xs) do x
        x + 1
    end
end

function closure(xs::Vector{Float64}, shift::Float64)
    add_shift = x -> x + shift
    return add_shift.(xs)
end

function inbounds_loop(xs::Vector{Float64})
    acc = 0
    @inbounds for i in eachindex(xs)
        acc += xs[i]
    end
    return acc
end

function views_slice(xs::Matrix{Float64})
    @views column = xs[:, 1]
    return sum(column)
end

@kwdef struct Settings
    tolerance::Float64 = 1.0e-8
    steps::Int = 10
end

macro twice(ex)
    return esc(:($ex; $ex))
end

function package_macro(xs::Vector{Float64})
    @twice push!(xs, 1.0)
    return xs
end

@generated function generated_sum(xs::NTuple{N, Float64}) where {N}
    return Expr(:call, :+, (:(xs[$i]) for i in 1:N)...)
end

for op in (:double_eval, :triple_eval)
    factor = op === :double_eval ? 2 : 3
    @eval $op(x::Float64) = x * $factor
end

end
