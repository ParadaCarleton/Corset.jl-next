# runic: off
function classify(x)
    if x > 0
        return :positive
    elseif x >= 0
        return :zero
    elseif x == 1
        return :one
    elseif x == 2
        return :two
    end
end

function drain(queue)
    if pop!(queue) == 1
        return :one
    elseif pop!(queue) == 1
        return :second_one
    end
end

function poll(state, source)
    if state.ready
        return :ready
    elseif refresh!(state, source)
        return :refreshed
    elseif state.ready
        return :ready_after_refresh
    end
end

function nested(x)
    if x > 0
        return 1
    else
        if x > 0
            return 2
        end
    end
end

function guarded(x)
    x < 0 && return 0
    if x > 10
        return 10
    end
    map(item -> throw(item), x)
    throw_error(x)
    return x
end

function parse_header(io)
    eof(io) && @goto truncated
    header = read(io, UInt32)
    return header
    @label truncated
    error("truncated header")
end

module Script
return
const LOADED = true
end

# String contents differ only in spacing: distinct conditions.
function choose(x)
    if x == "a b"
        return 1
    elseif x == "a  b"
        return 2
    end
end
