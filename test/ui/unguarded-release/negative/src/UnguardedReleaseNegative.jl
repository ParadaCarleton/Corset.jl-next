# runic: off
module UnguardedReleaseNegative

# Nothing between acquire and release.
function touch(cache_lock::ReentrantLock)
    lock(cache_lock)
    unlock(cache_lock)
    return nothing
end

# Release in `finally` of `try` after acquire.
function store!(cache::Dict{String, Int}, cache_lock::ReentrantLock, key::String)
    lock(cache_lock)
    try
        cache[key] = parse(Int, key)
    finally
        unlock(cache_lock)
    end
    return nothing
end

# Do-block forms and `@lock` release on exception.
function save(path::String, data::Vector{UInt8}, cache_lock::ReentrantLock)
    lock(cache_lock) do
        parse(Int, path)
    end
    @lock cache_lock parse(Int, path)
    open(path, "w") do io
        write(io, data)
    end
    return nothing
end

# Code between cannot throw.
function mark(guard::ReentrantLock, count::Int)
    lock(guard)
    total = count + 1
    unlock(guard)
    return total
end

# Throwing work runs before `open`; caller owns returned stream.
struct Opened
    io::IOStream
    count::Int
end
function opened(path::String, text::String)::Opened
    count = parse(Int, text)
    return Opened(open(path, "a"), count)
end

# Throw of `write` can leave stream lock held (`@_lock_ios`); throw-exit hold reaches `finally` but gives no fact.
function appended(path::String, text::String)::Int
    stream = opened(path, text)
    try
        return write(stream.io, text)
    finally
        close(stream.io)
    end
end

end
