using Test: @test, @testset

"""Include test `file` in own module: names of one file, imports included, never clash with names of other file."""
function isolated(file::String)::Any
    holder = Core.eval(Main, Expr(:module, true, Symbol("Test_", splitext(file)[1]), Expr(:block)))
    return Base.include(holder, joinpath(@__DIR__, file))
end

"""Run speed tests in process, or in child process without coverage instrumentation, which slows code many times."""
function perf()::Any
    Base.JLOptions().code_coverage == 0 && return isolated("perf.jl")
    command = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) $(joinpath(@__DIR__, "perf.jl"))`
    return @test success(pipeline(command; stdout, stderr))
end

const FILES = [
    "units.jl", "standins.jl", "signatures.jl", "inference.jl", "widening.jl", "hard_arrays.jl", "guesses.jl", "narrowing.jl",
    "own_code.jl", "specialize.jl", "effects.jl", "summary_cache.jl", "names.jl", "indices.jl", "lifecycle.jl", "registry.jl", "ui.jl", "properties.jl", "cli.jl",
    "cache.jl", "invalidation.jl", "perf.jl",
]

# Arguments pick files (`julia --project=test test/runtests.jl names.jl lifecycle.jl`); no argument runs every file.
const SELECTED = isempty(ARGS) ? FILES : ARGS
isempty(setdiff(SELECTED, FILES)) || error("unknown test files $(setdiff(SELECTED, FILES)); choose from $(FILES)")

# Outer testset reports failures at end; testset per file records load error. Later files run in both cases.
@testset "Corset" begin
    for file in SELECTED
        @testset "$file" begin
            file == "perf.jl" ? perf() : isolated(file)
        end
    end
end
