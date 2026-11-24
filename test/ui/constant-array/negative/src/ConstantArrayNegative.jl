# runic: off
"""Fixture of `constant-array`: filled arrays that method writes, grows or returns."""
module ConstantArrayNegative

basis(n::Int) = (e = zeros(n); e[1] = 1.0; e)

returned(n::Int) = ones(n)

grown(n::Int) = (a = zeros(n); push!(a, 1.0); sum(a))

shifted(n::Int) = (a = zeros(n); a .+= 1.0; sum(a))

# Call can return array itself, or view that holds it: write through result writes array.
settled(a::Matrix{Float64}) = a
settled_write(n::Int) = (r = settled(zeros(n, n)); r[1, 1] = 1.0; sum(r))
floated(n::Int) = (a = zeros(n); b = float(a); b[1] = 1.0; sum(a))
unary(n::Int) = (a = zeros(n, n); b = *(a); b[1, 1] = 1.0; sum(a))
head(a::Vector{Float64}) = view(a, 1:2)
headed(n::Int) = (a = zeros(n); head(a) .= 1.0; sum(a))

end
