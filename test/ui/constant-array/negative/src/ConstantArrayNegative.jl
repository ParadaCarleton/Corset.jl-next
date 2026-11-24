# runic: off
"""Fixture of `constant-array`: filled arrays that method writes, grows or returns."""
module ConstantArrayNegative

basis(n::Int) = (e = zeros(n); e[1] = 1.0; e)

returned(n::Int) = ones(n)

grown(n::Int) = (a = zeros(n); push!(a, 1.0); sum(a))

shifted(n::Int) = (a = zeros(n); a .+= 1.0; sum(a))

block(x::Vector{Float64}) = (a = zeros(length(x) + 1); a[1:end-1] .= x; sum(a))

function marked(groups::Vector{Vector{Int}}, n::Int)
    seen = falses(n)
    total = 0
    for group in groups
        total += count(view(seen, group))
        seen[group] .= true
    end
    return total
end

end
