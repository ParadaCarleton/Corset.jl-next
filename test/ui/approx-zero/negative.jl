# runic: off
function near_zero(x, tol)
    return isapprox(x, 0; atol = tol)
end

x ≈ 1
abs(x) < 1.0e-8

# Quoted code and macro arguments with `{}` are data.
expression = :(x ≈ 0)
pattern = @pattern {x} ≈ 0
