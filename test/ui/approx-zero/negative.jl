function near_zero(x, tol)
    return isapprox(x, 0; atol = tol)
end

x ≈ 1
abs(x) < 1.0e-8
