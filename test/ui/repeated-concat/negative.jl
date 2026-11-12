# runic: off
function gather(parts)
    result = Int[]
    for part in parts
        append!(result, part)
    end
    return result
end

combined = vcat(left, right)
