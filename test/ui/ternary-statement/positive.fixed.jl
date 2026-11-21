# runic: off
function keep_positive!(positive, xs)
    for x in xs
        if x > 0
            push!(positive, x)
        end
    end
    return positive
end

function sort_signs!(negative, positive, xs)
    for x in xs
        if x < 0
            push!(negative, x)
        elseif x > 0
            push!(positive, x)
        end
    end
    return negative, positive
end

function keep_waiting!(waiting, xs)
    for x in xs
        if !isready(x)
            push!(waiting, x)
        end
    end
    return waiting
end

function route!(a, b, c, first, second)
    if first
        if second
            push!(a, 1)
        else
            push!(b, 1)
        end
    else
        push!(c, 1)
    end
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
    if balanced(hold)
        delete!(state, key)
    else
        state[key] = hold
    end
    return state
end

function stage!(staged, found, method, generated)
    if generated
        isempty(staged) && return nothing
        push!(staged, method)
    else
        push!(found, method)
    end
    return found
end

function assign_branch!(xs, f)
    if (y = f())
        push!(xs, y)
    else
        empty!(xs)
    end
    if !(a => b)
        push!(xs, (x for x in xs))
    end
    return xs
end
