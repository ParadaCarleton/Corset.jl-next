# Callees of `callers.jl`: store entries of callers record their code.
increment(x) = x + 1
step_of(x::Real) = 2x
Base.isless(::Val{:inference_cases}, ::Val{:inference_cases}) = false
counter::Int = 0
