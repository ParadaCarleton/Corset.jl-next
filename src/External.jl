"""
`external` stage: run external checks on loaded package; keep their output as facts.

`Test.detect_ambiguities` runs on package modules, as Aqua.jl does. Pair with method outside package methods
(other module, generated method, file outside analyzed files) drops.
Aqua.jl offers piracy check only as `@test`, so stage calls internal `Aqua.Piracy.is_pirate`; compat pins minor version.
"""
module External

using ..Facts: ExternalFacts, PackageFacts, MethodSite
using Aqua: Aqua
using Test: Test

"""Source order of method site: file, first byte, then signature text for sites on one line."""
source_order(site::MethodSite)::Tuple{String, Int, String} = (site.span.file, site.span.first_byte, string(site.method.sig))

"""
Pairs of `package` method sites `Test.detect_ambiguities` reports: earlier site first, pairs sorted by later site.
It returns pair of methods on one line in both orders; each pair keeps one entry.
"""
function ambiguities(package::PackageFacts)::Vector{Tuple{MethodSite, MethodSite}}
    sites = IdDict{Method, MethodSite}(site.method => site for site in package.methods)
    found = Tuple{MethodSite, MethodSite}[]
    for (one, other) in Test.detect_ambiguities(package.modules...)
        haskey(sites, one) && haskey(sites, other) || continue
        earlier, later = sort([sites[one], sites[other]]; by = source_order)
        push!(found, (earlier, later))
    end
    return sort!(unique!(found); by = pair -> (source_order(last(pair)), source_order(first(pair))))
end

"""Types and functions package `modules` define, by binding; Aqua.jl gives each extension own package id, so extensions need list."""
function owned(modules::Vector{Module})::Vector{Union{Function, Type}}
    package, found = Set(modules), Union{Function, Type}[]
    for mod in modules, name in names(mod; all = true)
        isdefined(mod, name) || continue
        binding = getglobal(mod, name)
        # `Union` alias has no parent module; Aqua.jl reads union members one by one.
        definition = binding isa Function || Base.unwrap_unionall(binding) isa DataType
        definition && parentmodule(binding) in package && push!(found, binding)
    end
    return found
end

"""Sites of `package` methods Aqua.jl calls type piracy: package owns neither function nor any argument type."""
function piracies(package::PackageFacts)::Vector{MethodSite}
    own = owned(package.modules)
    return filter(site -> Aqua.Piracy.is_pirate(site.method; treat_as_own = own), package.methods)
end

"""External facts of loaded `package`."""
external_facts(package::PackageFacts)::ExternalFacts = ExternalFacts(ambiguities(package), piracies(package))

end
