# Script fixture: one or more positive cases per family H footgun.
using Base.Threads

# 57 boxed-capture: closure rebinds captured variable.
function counter()
    n = 0
    f = () -> (n += 1)
    f(); f()
    return n
end

# 57 negative: captured, never rebound.
function reader()
    n = 0
    f = () -> n + 1
    return f()
end

# 61 soft-scope: top-level loop assigns global.
total = 0
for x in 1:3
    total += x
end

# 61 negative: explicit global.
acc = 0
for x in 1:3
    global acc += x
end

# 62 try-scope: first assigned in try, read after.
function tryread()
    try
        y = rand()
    catch
    end
    return y
end

# 63 world-age: function defined by eval, called in same world.
@eval g() = 1
g()

# 69 threaded-race: unsynchronized update in threaded loop.
function race(xs)
    s = 0.0
    @threads for x in xs
        s += x
    end
    return s
end

# Shadowing: local shadows global.
const scale = 2
function shadow(v)
    scale = 3
    return scale * v
end
