# Methods with argument no stand-in fits (`MethodSignatures.bare`), keyed as blame TSV keys them.
# Usage: julia --project=. bare_list.jl Distances
include("package.jl")
include("corset_shim.jl")
const STRUCTS = Signatures.struct_stand_ins(package_structs())
open(joinpath(@__DIR__, "results", "$(PKG)-bare.tsv"), "w") do io
    for m in METHODS
        bare = Signatures.method_signatures(m, STRUCTS).bare
        isempty(bare) || println(io, m.name, " ", m.file, ":", m.line, "\t", join(bare, ","))
    end
end
