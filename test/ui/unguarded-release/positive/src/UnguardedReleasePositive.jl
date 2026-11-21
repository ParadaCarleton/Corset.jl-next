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

# Callee acquires; caller releases.
hold!(cache_lock::ReentrantLock) = lock(cache_lock)

function store_held!(cache::Dict{String, Int}, cache_lock::ReentrantLock, key::String)
    hold!(cache_lock)
    cache[key] = parse(Int, key)
    unlock(cache_lock)
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

end
