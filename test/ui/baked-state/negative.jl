# runic: off
# Function bodies, `__init__` and closures run when called.
function workers()
    return Threads.nthreads()
end
workers_short() = Threads.nthreads()
const NTHREADS = Ref(0)
function __init__()
    NTHREADS[] = Threads.nthreads()
    global HOME = homedir()
end
const LAZY_HOME = () -> homedir()
macro stamp()
    stamp = time()
    return stamp
end

# Pure builders.
const TABLE = build_table()
const DATA = joinpath(@__DIR__, "data")
const LOCK = ReentrantLock()
const RANDOM = rand

# Other macros get syntax and may never run it.
const PATTERN = @pattern homedir()

# Local assignments: `let` bindings, `local`, loop body.
let threads = Threads.nthreads()
    local home = homedir()
end
for index in 1:2
    seed = rand()
end

# State read outside assignment, or written.
@info "threads" Threads.nthreads()
configure(threads = Threads.nthreads())
ENV["MODE"] = "fast"
