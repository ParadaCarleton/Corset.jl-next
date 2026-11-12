function total(a)
    s = zero(eltype(a))
    for i in eachindex(a)
        s += a[i]
    end
    return s
end

cols(m) = [m[:, j] for j in axes(m, 2)]
last_part(a) = a[eachindex(a)]
