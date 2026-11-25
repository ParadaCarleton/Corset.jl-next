# Write `src/Effects/engine/foreign_gmp_mpfr.jl`: effects of MPFR and GMP C functions, read from their headers.
# Run: julia --project=gen/foreign gen/foreign/generate.jl [header-dir [clang-builtin-include-dir]]
# Needs `symbols.txt` (from `scan.jl`), `mpfr.h` and `gmp.h`. CI lacks the headers; the committed file is the source of truth.
using Clang: Clang
using Clang.LibClang: CXType_Pointer, CXType_Void, CXType_FunctionProto, CXType_Invalid
using Clang.LibClang: clang_getCanonicalType, clang_getPointeeType, clang_isConstQualifiedType, clang_getResultType
using Clang.LibClang: clang_getCursorType, clang_getNumArgTypes, clang_getArgType, clang_Cursor_isVariadic

const INCLUDE = isempty(ARGS) ? "/usr/include" : first(ARGS)
const BUILTIN = length(ARGS) < 2 ? last(sort!(filter(isdir, readdir("/usr/lib/clang"; join = true)))) * "/include" : last(ARGS)
const OUTPUT = joinpath(@__DIR__, "..", "..", "src", "Effects", "engine", "foreign_gmp_mpfr.jl")

# Global state: MPFR manual 5.13 (exception related functions), GMP manual 4.7 (custom allocation).
const OPEN = Set([:mpfr_set_emin, :mpfr_set_emax, :mpfr_clear_flags, :__gmp_set_memory_functions, :__gmp_set_alloc_overflow_function])

# Variadic or pointer-returning: `calls.jl` holds their entries, with manual citations.
const HAND = Set([:mpfr_asprintf, :mpfr_free_str, :__gmpz_limbs_write, :__gmpz_get_str, :__gmpz_export])

"""Version of library from `header` text: MPFR's string macro, or GMP's three version macros."""
function version_of(text::String, library::Symbol)::String
    library === :mpfr && return only(match(r"MPFR_VERSION_STRING\s+\"([^\"]+)\"", text).captures)
    parts = [only(match(Regex("define __GNU_MP_VERSION$suffix\\s+(\\d+)"), text).captures) for suffix in ("", "_MINOR", "_PATCHLEVEL")]
    return join(parts, ".")
end

"""Role of each parameter of function type `type`: `:write` for pointer to non-const, `:read` for pointer to const, else `:scalar`."""
function roles(name::Symbol, type::Any)::Vector{Symbol}
    return map(0:(clang_getNumArgTypes(type) - 1)) do index
        parameter = clang_getCanonicalType(clang_getArgType(type, index))
        parameter.kind == CXType_Pointer || return :scalar
        pointee = clang_getPointeeType(parameter)
        pointee.kind == CXType_FunctionProto && error("$name: function pointer parameter $(index + 1)")
        return clang_isConstQualifiedType(pointee) != 0 ? :read : :write
    end
end

"""Positions of `role` among `roles`."""
positions(role::Symbol, found::Vector{Symbol})::String = string(findall(==(role), found))

"""Entry line for function `name` with parameter `found` roles."""
function entry(name::Symbol, found::Vector{Symbol})::String
    fields = String[]
    :write in found && push!(fields, "writes = " * positions(:write, found))
    :read in found && push!(fields, "reads = " * positions(:read, found))
    return "    :$name => CallEffects($(join(fields, ", "))),"
end

wanted = Symbol.(readlines(joinpath(@__DIR__, "symbols.txt")))
wrapper = joinpath(mktempdir(), "wrapper.h")
write(wrapper, "#include <stdint.h>\n#include <stdio.h>\n#include <stdarg.h>\n#include <gmp.h>\n#include <mpfr.h>\n")
unit = Clang.parse_header(Clang.Index(), wrapper, ["-I$INCLUDE", "-isystem", BUILTIN, "-DMPFR_USE_INTMAX_T"])
declared = Dict{Symbol, Any}()
for cursor in Clang.children(Clang.getTranslationUnitCursor(unit))
    cursor isa Clang.CLFunctionDecl && (declared[Symbol(first(split(Clang.name(cursor), "(")))] = cursor)
end
lines = String[]
for name in wanted
    name in OPEN && continue
    cursor = get(declared, name, nothing)
    isnothing(cursor) && error("$name: no declaration in headers")
    name in HAND && continue
    type = clang_getCursorType(cursor.cursor)
    clang_Cursor_isVariadic(cursor.cursor) != 0 && error("$name: variadic, add to HAND")
    result = clang_getCanonicalType(clang_getResultType(type))
    result.kind == CXType_Pointer && clang_isConstQualifiedType(clang_getPointeeType(result)) == 0 && error("$name: returns mutable pointer, add to HAND")
    push!(lines, entry(name, roles(name, type)))
end
mpfr_version = version_of(read(joinpath(INCLUDE, "mpfr.h"), String), :mpfr)
gmp_version = version_of(read(joinpath(INCLUDE, "gmp.h"), String), :gmp)
header = """
# Generated from MPFR $mpfr_version and GMP $gmp_version headers: `julia --project=gen/foreign gen/foreign/generate.jl`. Do not edit.
# Pointer to non-const is written, pointer to const is read. Symbols: `gen/foreign/symbols.txt`.
"""
body = """
\"\"\"
Effects of MPFR and GMP functions listed in `gen/foreign/symbols.txt`, by header constness (`mpfr_srcptr`, `const char *`
read; `mpfr_ptr`, `char *` written). Left out: `OPEN` and `HAND` of `gen/foreign/generate.jl`.
\"\"\"
const GENERATED_EFFECTS = Dict{Symbol, CallEffects}(
$(join(lines, "\n"))
)
"""
write(OUTPUT, header, "\n", body)
println(length(lines), " entries; MPFR $mpfr_version, GMP $gmp_version")
