# runic: off
function store!(cache, cache_lock, key, value)
    lock(cache_lock)
    cache[key] = value
    unlock(cache_lock)
    return nothing
end

function store_qualified!(cache, cache_lock, key, value)
    Base.lock(cache_lock)
    cache[key] = value
    Base.unlock(cache_lock)
    return nothing
end

# Target compares as source with whitespace runs collapsed.
function bump!(state)
    lock(state.locks[ 1 ])
    state.count += 1
    unlock(state.locks[  1 ])
    return nothing
end

function limited(slots)
    acquire(slots)
    work()
    release(slots)
    return nothing
end

function limited_qualified(slots)
    Base.acquire(slots)
    work()
    Base.release(slots)
    return nothing
end

function save(path, data)
    io = open(path, "w")
    write(io, data)
    close(io)
    return nothing
end

function save_qualified(path, data)
    io = Base.open(path, "w")
    write(io, data)
    Base.close(io)
    return nothing
end

# Release inside `try` body; `finally` does not release.
function logged!(cache_lock)
    try
        lock(cache_lock)
        work()
        unlock(cache_lock)
    finally
        @info "done"
    end
end

# Guarded pair, then unguarded pair on same lock.
function twice!(cache_lock)
    lock(cache_lock)
    try
        work()
    finally
        unlock(cache_lock)
    end
    lock(cache_lock)
    work()
    unlock(cache_lock)
    return nothing
end

lock(registry_lock)
register(item)
unlock(registry_lock)
