# runic: off
const NTHREADS = Threads.nthreads()
const WORKERS = nthreads()
const QUALIFIED_WORKERS = Base.Threads.nthreads()
const CORES = Sys.CPU_THREADS
const QUALIFIED_CORES = Base.Sys.CPU_THREADS
const API_KEY = ENV["API_KEY"]
const LEVEL = get(ENV, "LEVEL", "info")
const CONFIG = joinpath(homedir(), ".config")
const START = pwd()
const SCRATCH = tempdir()
const LOADED = time()
const STAMP = time_ns()
const BUILT = now()
const BUILT_UTC = Dates.now(Dates.UTC)
const SEED = rand(UInt)
const NOISE = randn(3)
const HOST = gethostname()
const PID = getpid()
const LIBRARY = Libdl.dlopen("libfoo")
const HANDLE = dlopen("libbar")
const COUNTER = cglobal((:counter, "libfoo"), Cint)
const BUFFER_START = pointer(BUFFER)

# Plain, `global` and typed assignments, and assignment into global.
threads = Threads.nthreads()
global home = homedir()
typed::Int = Threads.nthreads()
SLOTS[] = Threads.nthreads()

# Read nested in assigned expression.
const SIZES = fill(0, Threads.nthreads())
const OPTIONS = (threads = Threads.nthreads(),)
const FALLBACK = try
    ENV["FALLBACK"]
catch
    "none"
end
const TEMPLATE = :(run($(Threads.nthreads())))

"Thread count at load."
const DOCUMENTED = Threads.nthreads()

module Nested
begin
    const IN_BEGIN = Threads.nthreads()
end
if Sys.islinux()
    const IN_IF = Threads.nthreads()
elseif Sys.isapple()
    const IN_ELSEIF = Threads.nthreads()
else
    const IN_ELSE = Threads.nthreads()
end
let
    global IN_LET = Threads.nthreads()
end
@static if Sys.iswindows()
    const IN_STATIC = Threads.nthreads()
end
@eval const IN_EVAL = $(Threads.nthreads())
end
