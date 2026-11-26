# Write `src/Effects/engine/foreign_blas_lapack.jl`: effects of BLAS and LAPACK routines that LinearAlgebra calls.
# Run: julia --project=gen/foreign gen/foreign/blas_lapack.jl LAPACK-SOURCE-DIR VERSION
# Source dir: Reference-LAPACK release tree of tag VERSION (its CMakeLists.txt can lag tag). CI lacks it.
using LinearAlgebra: LinearAlgebra
include("calls.jl")

const SOURCE, VERSION_TAG = ARGS
const OUTPUT = joinpath(@__DIR__, "..", "..", "src", "Effects", "engine", "foreign_blas_lapack.jl")

"""Suffix of ILP64 Fortran symbols in libblastrampoline (`LinearAlgebra.BLAS.@blasfunc`)."""
const SUFFIX = "_64_"

"""Doxygen role comment of Reference-LAPACK argument: `*> \\param[in,out] A` (fixed form) or `!> ...` (free form)."""
const PARAM = r"^[*!]>\s*\\param\[(in|out|in,out)\]\s+(\w+)"i

"""
Whether `description` of `[in]` argument `name` says routine changes it: `?ormrz` documents "A is modified by the
routine but restored on exit". Store, even undone, is write: concurrent reader sees it.
"""
changed(name::String, description::String)::Bool = occursin(Regex("\\b$name\\s+(is|are)\\s+(modified|overwritten|destroyed)\\b", "i"), description)

"""Routines Reference-LAPACK lacks (`axpby`, extension of OpenBLAS and MKL): `calls.jl` holds their entries."""
const HAND = Set(["saxpby", "daxpby", "caxpby", "zaxpby"])

"""Old name of routine Reference-LAPACK 3.12 renamed, with new name: `?gemmt` became `?gemmtr`, same arguments."""
const RENAMED = Dict("sgemmt" => "sgemmtr", "dgemmt" => "dgemmtr", "cgemmt" => "cgemmtr", "zgemmt" => "zgemmtr")

"""Source file of routine `routine` (lowercase name) in `SOURCE`: BLAS, LAPACK, deprecated LAPACK or `ilaver`."""
function source_file(routine::String)::String
    dirs = ("BLAS/SRC", "SRC", "SRC/DEPRECATED", "INSTALL")
    found = [path for dir in dirs for extension in (".f", ".f90") for path in (joinpath(SOURCE, dir, routine * extension),) if isfile(path)]
    isempty(found) && error("$routine: no source file in $SOURCE")
    return only(found)
end

"""Code lines of Fortran `text`, continuation lines joined: fixed form marks continuation in column 6, free form ends line with `&`."""
function statements(text::String, free::Bool)::Vector{String}
    found = String[]
    for line in split(text, '\n')
        free && (line = first(split(line, '!')))
        isempty(strip(line)) && continue
        !free && line[1] in "*cC!" && continue
        if !free && length(line) >= 6 && isempty(strip(line[1:5])) && line[6] != ' '
            found[end] *= line[7:end]
        elseif free && !isempty(found) && endswith(rstrip(found[end]), '&')
            found[end] = rstrip(rstrip(found[end]), '&') * line
        else
            push!(found, line)
        end
    end
    return found
end

"""Formal arguments of routine `routine` in Fortran `text`, in order: argument list of its `SUBROUTINE` or `FUNCTION` statement."""
function formals(routine::String, text::String, free::Bool)::Vector{String}
    pattern = Regex("(?:SUBROUTINE|FUNCTION)\\s+$routine\\s*\\(([^)]*)\\)", "i")
    found = [match.captures[1] for match in (Base.match(pattern, line) for line in statements(text, free)) if !isnothing(match)]
    isempty(found) && error("$routine: no SUBROUTINE or FUNCTION statement")
    return uppercase.(strip.(split(first(found), ',')))
end

"""Role (`in`, `out`, `in,out`) and description of each documented argument of Fortran `text`, by uppercase name."""
function documented(routine::String, text::String)::Dict{String, Tuple{String, String}}
    found, current = Dict{String, Tuple{String, String}}(), nothing
    for line in split(text, '\n')
        param = match(PARAM, line)
        if !isnothing(param)
            role, name = lowercase(param.captures[1]), uppercase(param.captures[2])
            haskey(found, name) && first(found[name]) != role && error("$routine: argument $name has two roles")
            found[name], current = (role, ""), name
        elseif !isnothing(current) && startswith(line, r"[*!]>")
            role, description = found[current]
            found[current] = (role, description * " " * line[3:end])
        else
            current = nothing
        end
    end
    return found
end

"""Entry line for C function `name` of routine with argument `roles`: `out` written, `in` read, `in,out` both."""
function entry(name::Symbol, roles::Vector{String})::String
    writes = findall(in(("out", "in,out")), roles)
    reads = findall(in(("in", "in,out")), roles)
    fields = String[]
    isempty(writes) || push!(fields, "writes = $writes")
    isempty(reads) || push!(fields, "reads = $reads")
    return "    :$name => CallEffects($(join(fields, ", "))),"
end

"""Roles of arguments of routine of C function `name`; some LinearAlgebra call passes each (`counts` of C arguments)."""
function routine_roles(name::Symbol, counts::Vector{Int})::Vector{String}
    called = String(chopsuffix(string(name), SUFFIX))
    routine = get(RENAMED, called, called)
    path = source_file(routine)
    text = read(path, String)
    arguments, roles = formals(routine, text, endswith(path, ".f90")), documented(routine, text)
    found = map(arguments) do argument
        haskey(roles, argument) || error("$routine: argument $argument has no \\param role")
        role, description = roles[argument]
        role == "in" && changed(argument, description) && (println("$routine: [in] $argument is modified: written"); return "in,out")
        return role
    end
    # Shorter call sits in branch for other element type (`geqp3!` of complex matrix skips real call).
    maximum(counts) < length(found) && error("$routine: LinearAlgebra call passes $(maximum(counts)) of $(length(found)) arguments")
    return found
end

calls = module_calls((LinearAlgebra, LinearAlgebra.BLAS, LinearAlgebra.LAPACK))
counts = Dict{Symbol, Vector{Int}}()
for (name, count) in calls
    endswith(string(name), SUFFIX) && !(chopsuffix(string(name), SUFFIX) in HAND) && push!(get!(Vector{Int}, counts, name), count)
end
lines = [entry(name, routine_roles(name, counts[name])) for name in sort!(collect(keys(counts)))]
header = """
# Generated from Reference-LAPACK $VERSION_TAG sources and Julia $VERSION LinearAlgebra calls:
# `julia --project=gen/foreign gen/foreign/blas_lapack.jl LAPACK-SOURCE-DIR $VERSION_TAG`. Do not edit.
"""
body = """
\"\"\"
Effects of BLAS and LAPACK routines that LinearAlgebra calls, by `\\\\param` role comment of Reference-LAPACK source:
`[out]` argument written, `[in]` read, `[in,out]` both. Hidden string lengths after Fortran arguments hold no object.
\"\"\"
const BLAS_LAPACK_EFFECTS = Dict{Symbol, CallEffects}(
$(join(lines, "\n"))
)
"""
write(OUTPUT, header, "\n", body)
println(length(lines), " entries; Reference-LAPACK $VERSION_TAG, Julia $VERSION")
