# runic: off
"""Fixture of `constant-array`: filled arrays that method writes, grows or returns."""
module ConstantArrayNegative

basis(n::Int) = (e = zeros(n); e[1] = 1.0; e)

returned(n::Int) = ones(n)

grown(n::Int) = (a = zeros(n); push!(a, 1.0); sum(a))

shifted(n::Int) = (a = zeros(n); a .+= 1.0; sum(a))

end
