# runic: off
function total(a)
    s = zero(eltype(a))
    for i in 1:length(a)
        s += a[i]
    end
    return s
end

cols(m) = [m[:, j] for j in 1:size(m, 2)]
last_part(a) = a[1:lastindex(a)]

ids = collect(1:length(a))
