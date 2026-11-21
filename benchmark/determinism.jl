# Fact sets of package over fresh compiles (`phase5.md`, Corpus go/no-go): each round deletes package image, then dumps
# facts in new process. One set passes.
# Usage: julia benchmark/determinism.jl <work> <Name> <rounds> [<julia>]
# `benchmark/effects.jl` makes <work>; <julia> defaults to running binary. Set JULIA_DEPOT_PATH to keep arms apart.

using SHA: sha256

"""Compiled-image directory of package `name` in first depot of `julia`."""
function image_directory(julia::Cmd, name::String)::String
    code = "print(joinpath(DEPOT_PATH[1], \"compiled\", \"v\$(VERSION.major).\$(VERSION.minor)\", ARGS[1]))"
    return read(`$julia --startup-file=no -e $code $name`, String)
end

"""Run `rounds` fresh compiles of `name` in `work` with `julia`; print each round and count of each fact set."""
function rounds(work::String, name::String, count::Int, julia::Cmd)::Nothing
    dump, images = joinpath(@__DIR__, "..", "diagnostics", "dump_facts.jl"), image_directory(julia, name)
    sets = Dict{String, Int}()
    for round in 1:count
        rm(images; recursive = true, force = true)
        facts = joinpath(work, "determinism-$name-$round.txt")
        run(`$julia --startup-file=no --project=$(joinpath(work, "env-$name")) $dump $name $(joinpath(work, name)) $facts`)
        digest = bytes2hex(open(sha256, facts))[1:12]
        sets[digest] = get(sets, digest, 0) + 1
        println("round ", round, ": lines=", countlines(facts), " sha=", digest)
    end
    println(length(sets) == 1 ? "one fact set" : "fact sets: $(length(sets))", " ", sort!(collect(sets); by = last, rev = true))
    return nothing
end

rounds(abspath(ARGS[1]), ARGS[2], parse(Int, ARGS[3]), length(ARGS) >= 4 ? `$(ARGS[4])` : Base.julia_cmd())
