"""
`external` stage: run external checks on loaded package; keep their output as facts.

`Test.detect_ambiguities` runs on package modules, as Aqua.jl does. Pair with method outside package methods
(other module, generated method, file outside analyzed files) drops.
"""
module External

using ..Facts: ExternalFacts, PackageFacts, MethodSite
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

"""External facts of loaded `package`."""
external_facts(package::PackageFacts)::ExternalFacts = ExternalFacts(ambiguities(package))

end
