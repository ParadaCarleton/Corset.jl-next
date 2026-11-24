# runic: off
module UnguardedReleasePositive

function store!(cache::Dict{String, Int}, cache_lock::ReentrantLock, key::String)
    lock(cache_lock)
    cache[key] = parse(Int, key)
    unlock(cache_lock)
    return nothing
end

function limited(slots::Base.Semaphore, path::String)
    Base.acquire(slots)
    text = read(path, String)
    Base.release(slots)
    return text
end

function save(path::String, data::Vector{UInt8})
    io = open(path, "w")
    write(io, data)
    close(io)
    return nothing
end

# `trylock` holds on its success side.
function tried!(cache::Dict{String, Int}, cache_lock::ReentrantLock, key::String)
    if trylock(cache_lock)
        cache[key] = parse(Int, key)
        unlock(cache_lock)
    end
    return nothing
end

# Release inside `try` body; `finally` does not release.
function logged!(cache_lock::ReentrantLock, key::String)
    try
        lock(cache_lock)
        parse(Int, key)
        unlock(cache_lock)
    finally
        println("done")
    end
    return nothing
end

# Later argument may throw after `open` returns.
struct Opened
    io::IOStream
    count::Int
end
opened(path::String, text::String)::Opened = Opened(open(path, "a"), parse(Int, text))

# Package function takes held lock and can release it: count after call is unknown.
function recorded!(cache::Dict{String, Int}, cache_lock::ReentrantLock, key::String)
    lock(cache_lock)
    record(cache_lock, key)
    cache[key] = parse(Int, key)
    unlock(cache_lock)
    return nothing
end
record(cache_lock::ReentrantLock, key::String) = println(islocked(cache_lock), key)

end
