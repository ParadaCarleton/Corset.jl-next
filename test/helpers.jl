# Helpers of command-line tests that `cli.jl` and `cache.jl` share. Each test file includes it in own module.

using Corset: Corset

"""Exit code, standard output and standard error of `corset args...`."""
function corset(args::String...)::Tuple{Int, String, String}
    out, err = IOBuffer(), IOBuffer()
    code = Corset.CLI.execute(String[args...], out, err; launch = false, cache = nothing)
    return code, String(take!(out)), String(take!(err))
end

"""Line `--timings` prints: stage name, then wall, compile and garbage collection seconds."""
const TIMING_ROW = r"^corset: stage (\S+(?: \S+)*) +[\d.]+ s wall +[\d.]+ s compile +[\d.]+ s gc$"

"""Timing rows of `effects` stage: its steps as each ends, then stage."""
const EFFECTS_ROWS = ["effects name tier", "effects bodies", "effects reach", "effects solve", "effects verdicts", "effects"]

"""Stage names of `--timings` lines in standard error text `err`, in order."""
timing_rows(err::String)::Vector{String} = [String(match(TIMING_ROW, line)[1]) for line in split(err, '\n') if occursin(TIMING_ROW, line)]

const LIBRARY = joinpath(@__DIR__, "config", "library")
# Package stage loads fixture packages in place, so test environment must load them from their roots.
LIBRARY in LOAD_PATH || push!(LOAD_PATH, LIBRARY)

"""Run `body` on new package `name` written under `parent` from `files` (path => text), with package on load path."""
function with_package(body::Function, parent::String, name::String, files::Pair{String, String}...)::Nothing
    mktempdir(parent) do package
        write(joinpath(package, "Project.toml"), "name = \"$name\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n\n[preferences.Corset]\nkind = \"library\"\n")
        for (path, text) in files
            mkpath(dirname(joinpath(package, path)))
            write(joinpath(package, path), text)
        end
        push!(LOAD_PATH, package)
        try
            body(package)
        finally
            pop!(LOAD_PATH)
        end
    end
    return nothing
end
