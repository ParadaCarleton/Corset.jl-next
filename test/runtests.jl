using Corset: Corset
using ParallelTestRunner: ParallelTestRunner
# Test sets of property tests hold Supposition reports; runner deserializes them only with package loaded.
using Supposition: Supposition

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

"""
Expression worker runs for each file, in own module: `PERF` for speed tests, `include` of file for others.
Runner process deserializes test sets of file, so `plain_reports!` of `INIT` reduces Supposition reports first.
"""
const SUITE = Dict(
    file => :(
        try
            $(file == "perf.jl" ? PERF : :(include($(joinpath(@__DIR__, file)))))
        finally
            plain_reports!(Test.get_testset())
        end
    ) for file in FILES
)

"""Code each test module runs before its file: defines `plain_reports!`."""
const INIT = :(include($(joinpath(@__DIR__, "plain_reports.jl"))))

# Temp directory in `test` enters cache keys of concurrent files, unless dot prefix keeps it out of `tree_files`.
const BARE = filter(file -> occursin("mktempdir(@__DIR__)", read(joinpath(@__DIR__, file), String)), [FILES; "helpers.jl"])
isempty(BARE) || error("temp directory without dot prefix in $(BARE): use `mktempdir(@__DIR__; prefix = \".jl_\")`")

# Arguments pick files (`julia --project=test test/runtests.jl names.jl lifecycle.jl`); flags such as `--jobs=N` go to runner.
const PICKED = filter(!startswith("-"), ARGS)
isempty(setdiff(PICKED, FILES)) || error("unknown test files $(setdiff(PICKED, FILES)); choose from $(FILES)")

"""
Files that get own worker with several threads: `ui.jl` runs cases as tasks; `cli.jl` relaunches Corset, whose child
copies thread count of its parent, and its crash test needs several threads.
"""
const THREADED = ["ui.jl", "cli.jl"]

"""Threads of each `THREADED` worker: those files share threads of this process, but crash test needs two at least."""
const FILE_THREADS = max(2, Threads.nthreads(:default) ÷ length(THREADED))

"""
Worker for test `name`: own worker with `FILE_THREADS` for `THREADED` file, which runner stops once file ends. `nothing`
sends other files to pool workers, which run one thread each: thread per worker in pool would oversubscribe cores.
"""
file_worker(name::String)::Union{Nothing, ParallelTestRunner.PTRWorker} =
    name in THREADED ? ParallelTestRunner.addworker(; exeflags = ["--threads=$FILE_THREADS"]) : nothing

println("test threads of $(join(THREADED, " and ")) workers: $FILE_THREADS each")
ParallelTestRunner.runtests(Corset, ARGS; testsuite = SUITE, serial = SERIAL, serial_position = :after, test_worker = file_worker, init_code = INIT)
