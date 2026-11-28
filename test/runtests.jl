using Corset: Corset
using ParallelTestRunner: ParallelTestRunner

const FILES = [
    "units.jl", "standins.jl", "signatures.jl", "inference.jl", "widening.jl", "hard_arrays.jl", "guesses.jl", "narrowing.jl",
    "own_code.jl", "specialize.jl", "effects.jl", "summary_cache.jl", "names.jl", "indices.jl", "lifecycle.jl", "registry.jl", "ui.jl", "properties.jl", "cli.jl",
    "cache.jl", "invalidation.jl", "perf.jl",
]

"""Files that run alone after parallel batch: speed tests measure time, cache tests compare keys of whole `test` tree."""
const SERIAL = ["cache.jl", "summary_cache.jl", "perf.jl"]

"""Speed tests: in worker, or in child process without coverage instrumentation, which slows code many times."""
const PERF = quote
    file = $(joinpath(@__DIR__, "perf.jl"))
    if Base.JLOptions().code_coverage == 0
        include(file)
    else
        @test success(pipeline(Cmd([Base.julia_cmd().exec; "--code-coverage=none"; "--project=$(Base.active_project())"; file]); stdout, stderr))
    end
end

"""Expression worker runs for each file, in own module: `PERF` for speed tests, `include` of file for others."""
const SUITE = Dict(file => file == "perf.jl" ? PERF : :(include($(joinpath(@__DIR__, file)))) for file in FILES)

# Temp directory in `test` enters cache keys of concurrent files, unless dot prefix keeps it out of `tree_files`.
const BARE = filter(file -> occursin("mktempdir(@__DIR__)", read(joinpath(@__DIR__, file), String)), [FILES; "helpers.jl"])
isempty(BARE) || error("temp directory without dot prefix in $(BARE): use `mktempdir(@__DIR__; prefix = \".jl_\")`")

# Arguments pick files (`julia --project=test test/runtests.jl names.jl lifecycle.jl`); flags such as `--jobs=N` go to runner.
const PICKED = filter(!startswith("-"), ARGS)
isempty(setdiff(PICKED, FILES)) || error("unknown test files $(setdiff(PICKED, FILES)); choose from $(FILES)")

# Workers start without `--threads` of this process; same count lets UI cases run on all threads of each worker.
const THREADS = ["--threads=$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))"]
println("test threads per worker: $(Threads.nthreads(:default))")
ParallelTestRunner.runtests(Corset, ARGS; testsuite = SUITE, serial = SERIAL, serial_position = :after, exeflags = THREADS)
