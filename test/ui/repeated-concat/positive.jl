# runic: off
function gather(parts)
    result = Int[]
    for part in parts
        result = vcat(result, part)
    end
    return result
end

while more()
    rows = [rows; next_row()]
end
