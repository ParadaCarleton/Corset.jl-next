# Write `symbols.txt`: MPFR and GMP C functions that Base (running Julia version) and SpecialFunctions call.
# Run: julia --project=gen/foreign gen/foreign/scan.jl
using SpecialFunctions: SpecialFunctions

"""Insert into `names` the C function name of every foreign call in `code`."""
function foreign_names!(names::Set{Symbol}, code::Any)::Nothing
    if code isa Expr
        if code.head === :foreigncall
            target = code.args[1]
            target isa QuoteNode && (target = target.value)
            target isa Expr && target.head === :tuple && (target = target.args[1])
            target isa QuoteNode && (target = target.value)
            target isa Tuple && (target = first(target))
            push!(names, Symbol(target))
        end
        foreach(argument -> foreign_names!(names, argument), code.args)
    elseif code isa Core.CodeInfo
        foreach(statement -> foreign_names!(names, statement), code.code)
    end
    return nothing
end

const SCANNED = (Base.MPFR, Base.GMP, Base.GMP.MPZ, Base.GMP.MPQ, SpecialFunctions)
names = Set{Symbol}()
Base.visit(Core.methodtable) do method
    method.module in SCANNED || return nothing
    foreign_names!(names, Base.uncompressed_ast(method))
end
# Extra functions: no Base or SpecialFunctions call, but other numeric packages call them.
const EXTRA = [:mpfr_get_d, :mpfr_cmp, :mpfr_swap, :mpfr_remquo, :mpfr_strtofr]
mine = sort!(union(filter(name -> startswith(string(name), r"mpfr_|__gmp"), collect(names)), EXTRA))
write(joinpath(@__DIR__, "symbols.txt"), join(mine, "\n"), "\n")
println(length(mine), " symbols; Julia ", VERSION)
