using Corset: Corset
using Malt: Malt
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

"""Worker of `ui.jl` once runner starts it; runner stops only workers of its own pool."""
const UI_WORKER = Ref{Union{Nothing, ParallelTestRunner.PTRWorker}}(nothing)

"""
Worker for test `name`: `ui.jl` runs cases as tasks, so its worker gets every thread of this process. `nothing` sends
other files to pool workers, which run one thread each: thread per worker in pool would oversubscribe cores.
"""
function file_worker(name::String)::Union{Nothing, ParallelTestRunner.PTRWorker}
    name == "ui.jl" || return nothing
    UI_WORKER[] = ParallelTestRunner.addworker(; exeflags = ["--threads=$(Threads.nthreads(:default))"])
    return UI_WORKER[]
end

println("test threads of ui.jl worker: $(Threads.nthreads(:default))")
try
    ParallelTestRunner.runtests(Corset, ARGS; testsuite = SUITE, serial = SERIAL, serial_position = :after, test_worker = file_worker)
finally
    # Stop lets worker exit, so it writes coverage files; killed process writes none.
    isnothing(UI_WORKER[]) || Malt.stop(something(UI_WORKER[]))
end
