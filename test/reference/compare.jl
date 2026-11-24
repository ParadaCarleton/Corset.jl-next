# Compare Corset with reference linters ReLint and LintApp on shared corpus; `allowlist.toml` maps their rules.
# Usage: julia --project=test test/reference/compare.jl
using Corset: Corset
using Corset.Facts: FactSet, Finding, Label, Role, Ban
using JSON: JSON
using TOML: TOML
using Test: @test, @testset

const ROOT = dirname(dirname(@__DIR__))
const CORPUS = [joinpath(ROOT, "test", "ui"), joinpath(ROOT, "lib", "CorsetLegacy", "src")]
const TOOLS = ["relint", "lintapp"]

"""Allowlist entry: reference rule, message pattern, and Corset rule or reason to allow."""
struct Entry
    rule::String
    message::Regex
    corset::Union{Nothing, String}
    allow::Union{Nothing, String}
end

"""Entry from allowlist `table`; wrong keys, or not exactly one of `corset` and `allow`, throw."""
function entry(table::Dict{String, Any})::Entry
    keys(table) ⊆ Set(["rule", "message", "corset", "allow"]) || throw(ArgumentError("unknown key in $table"))
    xor(haskey(table, "corset"), haskey(table, "allow")) || throw(ArgumentError("give one of `corset` and `allow`: $table"))
    return Entry(table["rule"], Regex(get(table, "message", "")), get(table, "corset", nothing), get(table, "allow", nothing))
end

"""Reference report Corset rejects on purpose: `tool` reports `rule` at line holding `code` in `file`, relative to repository."""
struct Disagreement
    tool::String
    file::String
    rule::String
    code::String
    reason::String
end

"""Disagreement from allowlist `table`; every key is required, and other keys throw."""
function disagreement(table::Dict{String, Any})::Disagreement
    keys(table) == Set(["tool", "file", "rule", "code", "reason"]) || throw(ArgumentError("give tool, file, rule, code and reason: $table"))
    return Disagreement(table["tool"], table["file"], table["rule"], table["code"], table["reason"])
end

"""Rule names and reports of `tool` on `CORPUS`, run in its own environment."""
function reference(tool::String, scratch::String)::Dict{String, Any}
    environment, out = joinpath(@__DIR__, tool), joinpath(scratch, "$tool.json")
    julia = `$(Base.julia_cmd()) --startup-file=no --project=$environment`
    run(`$julia -e 'using Pkg; Pkg.instantiate()'`)
    run(`$julia $(joinpath(environment, "run.jl")) $out $CORPUS`)
    return JSON.parsefile(out)
end

"""Lines each Corset finding covers in primary and cause labels, by file and rule; parse errors count as rule `parse-error`."""
function corset_lines()::Dict{Tuple{String, String}, Set{Int}}
    lines = Dict{Tuple{String, String}, Set{Int}}()
    for root in CORPUS
        files = [Corset.Syntax.parse_file(path, read(path, String), Role.package) for path in Corset.Discovery.walk_files(root)]
        facts = FactSet(files, String[], Ban[], nothing, nothing, nothing, nothing, nothing, nothing)
        starts = Dict(file.path => [1; findall(==(UInt8('\n')), codeunits(file.text)) .+ 1] for file in files)
        line(path::String, byte::Int)::Int = searchsortedlast(starts[path], byte)
        for finding in [Corset.Engine.run_rules(facts); Corset.Syntax.parse_problems(facts)], label in [finding.primary; finding.causes]
            span = label.span
            union!(get!(Set{Int}, lines, (span.file, string(finding.rule))), line(span.file, span.first_byte):line(span.file, span.last_byte))
        end
    end
    return lines
end

@testset "reference linters" begin
    allowlist = TOML.parsefile(joinpath(@__DIR__, "allowlist.toml"))
    @test keys(allowlist) == Set([TOOLS; "disagree"])
    disagreements, used = disagreement.(allowlist["disagree"]), Set{Int}()
    code(report::AbstractDict{String})::String = strip(readlines(report["file"])[report["line"]])
    known = Set([[string(rule.name) for rule in Corset.Rules.REGISTRY]; string(Corset.Syntax.PARSE_ERROR)])
    lines = corset_lines()
    mktempdir(joinpath(ROOT, "test")) do scratch
        for tool in TOOLS
            entries = entry.(allowlist[tool])
            output = reference(tool, scratch)
            rules = Set{String}(output["rules"])
            @testset "$tool" begin
                @test setdiff(rules, (entry.rule for entry in entries)) == Set()
                @test setdiff(Set(entry.rule for entry in entries), rules) == Set()
                @test setdiff(Set(entry.corset for entry in entries if !isnothing(entry.corset)), known) == Set()
                unmatched, missed, counts = String[], String[], Dict{String, Int}()
                for report in output["reports"]
                    place = "$(relpath(report["file"], ROOT)):$(report["line"]) $(report["rule"])"
                    index = findfirst(entry -> entry.rule == report["rule"] && occursin(entry.message, get(report, "message", "")), entries)
                    isnothing(index) && (push!(unmatched, "$place: $(get(report, "message", ""))"); continue)
                    corset = entries[index].corset
                    counts[something(corset, "allowed")] = get(counts, something(corset, "allowed"), 0) + 1
                    (isnothing(corset) || report["line"] in get(lines, (report["file"], corset), Set{Int}())) && continue
                    site_index = findfirst(
                        site -> (site.tool, site.file, site.rule, site.code) == (tool, relpath(report["file"], ROOT), report["rule"], code(report)), disagreements,
                    )
                    isnothing(site_index) ? push!(missed, "$place: no `$corset` finding") : push!(used, site_index)
                end
                println(tool, ": ", join(sort!(["$name $count" for (name, count) in counts]), ", "))
                @test unmatched == String[]
                @test missed == String[]
            end
        end
    end
    @test [site for (index, site) in enumerate(disagreements) if !(index in used)] == Disagreement[]
end
