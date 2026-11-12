# runic: off
function scale(values, factor)
    scaled = factor .* values
    for i in eachindex(scaled)
        scaled[i] += 1
    end
    return scaled
end

for _ in 1:3
    tick()
end
convert_all(::Type{T}, items) where {T} = T.(items)
plot(data; x = 1)
