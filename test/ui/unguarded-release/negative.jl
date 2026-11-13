# runic: off
# Nothing between acquire and release.
function touch(cache_lock)
    lock(cache_lock)
    unlock(cache_lock)
    return nothing
end

# Release in `finally` of `try` after acquire.
function store!(cache, cache_lock, key, value)
    lock(cache_lock)
    try
        cache[key] = value
    finally
        unlock(cache_lock)
    end
    return nothing
end

function limited(slots)
    Base.acquire(slots)
    try
        work()
    finally
        Base.release(slots)
    end
    return nothing
end

# Do-block forms release on exception.
function save(path, data, cache_lock)
    lock(cache_lock) do
        work()
    end
    open(path, "w") do io
        write(io, data)
    end
    return nothing
end

# Different targets.
function swap(first_lock, second_lock)
    lock(first_lock)
    work()
    unlock(second_lock)
    io = open(path)
    work()
    close(other)
    return nothing
end

# Two-argument `lock(f, l)` acquires and releases by itself.
function apply(cache_lock)
    lock(work, cache_lock)
    work()
    unlock(cache_lock)
    return nothing
end

# Release without acquire in same block.
function finish(cache_lock)
    work()
    unlock(cache_lock)
    return nothing
end

# Targets differ inside string: two locks.
function pick(locks)
    lock(locks["a b"])
    work()
    unlock(locks["a  b"])
end
