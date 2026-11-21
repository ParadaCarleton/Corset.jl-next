# runic: off
function keep_positive!(positive, xs)
    for x in xs
        x > 0 ? push!(positive, x) : nothing
    end
    return positive
end

function sort_signs!(negative, positive, xs)
    for x in xs
        x < 0 ? push!(negative, x) : x > 0 ? push!(positive, x) : nothing
    end
    return negative, positive
end

function keep_waiting!(waiting, xs)
    for x in xs
        isready(x) ? nothing : push!(waiting, x)
    end
    return waiting
end

function route!(a, b, c, first, second)
    first ? (second ? push!(a, 1) : push!(b, 1)) : push!(c, 1)
    return a
end

function shared_line!(a, flag)
    flag ? push!(a, 1) : push!(a, 2); push!(a, 3)
    return a
end

function constant_branches(flag)
    flag ? 1 : 2
    return flag
end

function record!(state, key, hold)
    balanced(hold) ? delete!(state, key) : (state[key] = hold)
    return state
end

function stage!(staged, found, method, generated)
    (generated) ? (isempty(staged) && return nothing; push!(staged, method)) : push!(found, method)
    return found
end

function assign_branch!(xs, f)
    (y = f()) ? push!(xs, y) : empty!(xs)
    (a => b) ? nothing : push!(xs, (x for x in xs))
    return xs
end
