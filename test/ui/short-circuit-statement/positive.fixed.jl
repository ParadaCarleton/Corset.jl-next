# runic: off
function check(n)
    if !(n >= 0)
        error("n must be non-negative")
    end
    return n
end

function first_ready(xs)
    for x in xs
        if isready(x)
            return x
        end
    end
    return nothing
end

function parse_args(args)
    if !isempty(args) && !verbose()
        println("args: ", args)
    end
    if isnothing(args)
        return
    end
    if !(args isa Vector) || !(length(args) > 1)
        return
    end
    return args
end

function nested(a, b)
    if !a
        if b
            run(a)
        end
    end
    return a
end

function shared_line(flag)
    flag && run(flag); run(flag)
    return flag
end

function grouped_terms(url, bad)
    if (task = fetch_later(url))
        return task
    end
    if (isempty(url) || isready(url)) && !bad
        return nothing
    end
    if !(bad ? url : nothing) && !@isdefined(url)
        error("no url")
    end
    if @isdefined(url)
        return url
    end
    return url
end
