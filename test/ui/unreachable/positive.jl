# runic: off
function classify(x)
    if x > 0
        return :positive
    elseif x < 0
        return :negative
    elseif x > 0
        return :unreachable
    end
    return :zero
end

function lookup(table, key, config)
    if haskey(table, key) && !isempty(table[key])
        return table[key]
    elseif config.mode == :strict || 0 < length(key) <= 2
        return nothing
    elseif haskey(table, key)  &&  !isempty(table[key])
        return missing
    elseif config.mode == :strict || 0 < length(key) <= 2
        return missing
    end
end

function first_even(items)
    for item in items
        continue
        println(item)
    end
    while true
        break
        step!(items)
        step!(items)
    end
    return nothing
    println("done")
end

function check(x)
    if x > 100
        error("too large: ", x)
        x = 100
    end
    try
        throw(ArgumentError("x"))
        cleanup(x)
    catch err
        rethrow(err)
        log_error(err)
    end
    return x
end

module Legacy
error("Legacy is removed; use Modern")
const LEVEL = 1
end

# Qualified Base function still ends block.
function stop_qualified()
    Base.error("stop")
    return 1
end
