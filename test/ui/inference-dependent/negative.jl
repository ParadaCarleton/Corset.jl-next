elementtype(f, x) = typeof(f(x))
result_type(a, b) = promote_type(eltype(a), eltype(b))
