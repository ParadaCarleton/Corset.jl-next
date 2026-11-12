# runic: off
function gather(parts)
    result = Int[]
    for part in parts
        append!(result, part)
    end
    return result
end

seen = Set(names)
for name in names
    name in seen && report(name)
end

combined = vcat(left, right)
