# runic: off
function check(n)
    n >= 0 || error("n must be non-negative")
    return n
end

function first_ready(xs)
    for x in xs
        isready(x) && return x
    end
    return nothing
end

function parse_args(args)
    isempty(args) || verbose() || println("args: ", args)
    !isnothing(args) || return
    (args isa Vector && length(args) > 1) || return
    return args
end

function nested(a, b)
    a || b && run(a)
    return a
end

function shared_line(flag)
    flag && run(flag); run(flag)
    return flag
end

function grouped_terms(url, bad)
    (task = fetch_later(url)) && return task
    !(isempty(url) || isready(url)) || bad || return nothing
    (bad ? url : nothing) || @isdefined(url) || error("no url")
    @isdefined(url) && return url
    return url
end
