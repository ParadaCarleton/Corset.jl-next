# runic: off
function counted(counter::Base.RefValue{Vector{Int}}, xs::Vector{Int})
    out = counter[]
    for x in xs
        push!(out, x)
    end
    return out
end

function preset(xs::Vector{Int})
    out = Int[0]
    for x in xs
        push!(out, x)
    end
    return out
end

function stopped(xs::Vector{Int})
    out = Int[]
    for x in xs
        x < 0 && break
        push!(out, x)
    end
    return out
end

function early(xs::Vector{Int})
    out = Int[]
    for x in xs
        push!(out, x < 0 ? (return Int[]) : x)
    end
    return out
end

function running(xs::Vector{Int})
    out = Int[]
    for x in xs
        push!(out, isempty(out) ? x : out[end] + x)
    end
    return out
end

function pairs_of(xs::Vector{Int}, ys::Vector{Int})
    out = Tuple{Int, Int}[]
    for x in xs, y in ys
        push!(out, (x, y))
    end
    return out
end

function both(xs::Vector{Int})
    out = Int[]
    for x in xs
        push!(out, x, -x)
    end
    return out
end

function split_even(xs::Vector{Int})
    out = Int[]
    for x in xs
        if iseven(x)
            push!(out, x)
        else
            push!(out, -x)
        end
    end
    return out
end

function apart(xs::Vector{Int})
    out = Int[]
    total = 0
    for x in xs
        push!(out, x)
    end
    return out, total
end

function inbounds(xs::Vector{Int})
    out = Int[]
    @inbounds for x in xs
        push!(out, x)
    end
    return out
end

function other(xs::Vector{Int}, sink::Vector{Int})
    out = Int[]
    for x in xs
        push!(sink, x)
    end
    return out
end

function fitting(candidates::Vector{Any}, bound::Type)
    found = Type[]
    for candidate in candidates
        candidate <: bound && push!(found, candidate)
    end
    return found
end

function applied(xs::Vector{Int}, f::Function)
    out = Any[]
    for x in xs
        push!(out, f(x))
    end
    return out
end
