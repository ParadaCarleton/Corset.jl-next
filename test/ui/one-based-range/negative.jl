function total(a)
    s = zero(eltype(a))
    for i in eachindex(a)
        s += a[i]
    end
    return s
end

first_n(n) = 1:n
two_to_end(a) = 2:length(a)
