# runic: off
function near_zero(x)
    return x ≈ 0
end

isapprox(0.0, residual(x))

# Relative tolerance and keyword of other macro leave zero exact.
@test x ≈ 0 rtol = 1e-3
@assert x ≈ 0 atol = 1e-3
