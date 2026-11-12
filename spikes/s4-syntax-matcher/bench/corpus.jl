# Run matcher on corpus src/ trees; print timing per 10k lines and findings as JSON.
# Usage: julia --project=spikes/s4-syntax-matcher spikes/s4-syntax-matcher/bench/corpus.jl [out.json]
const t_start = time()
include(joinpath(@__DIR__, "..", "src", "S4Matcher.jl"))
include(joinpath(@__DIR__, "..", "src", "rules.jl"))
import Distances, DataStructures, JSON

"""Julia files under `dir`, sorted."""
julia_files(dir::String)::Vector{String} = !isdir(dir) ? String[] : sort!([joinpath(root, f) for (root, _, fs) in walkdir(dir) for f in fs if endswith(f, ".jl")])

"""Parse and match every file in `sources`; return parse seconds, match seconds, findings."""
function run_corpus(rules::Vector{Rule}, sources::Vector{Pair{String, String}})::Tuple{Float64, Float64, Vector{Finding}}
    parse_seconds = match_seconds = 0.0
    findings = Finding[]
    for (file, src) in sources
        t0 = time_ns()
        tree = parse_file(src)
        t1 = time_ns()
        append!(findings, run_rules(rules, file, src, tree))
        t2 = time_ns()
        parse_seconds += (t1 - t0) / 1e9
        match_seconds += (t2 - t1) / 1e9
    end
    return parse_seconds, match_seconds, findings
end

function main(out::Union{Nothing, String})::Nothing
    rules = vcat(footgun_rules(), lintapp_shaped_rules())
    report = Dict{String, Any}("load_seconds" => time() - t_start)
    all_findings = Finding[]
    for m in (Distances, DataStructures, JSON)
        root = pkgdir(m)
        sources = [relpath(f, root) => read(f, String) for d in ("src", "ext") for f in julia_files(joinpath(root, d))]
        lines = sum(count(==('\n'), s) for (_, s) in sources)
        cold = @elapsed run_corpus(rules, sources)
        runs = [run_corpus(rules, sources) for _ in 1:20]
        parse_s = minimum(r[1] for r in runs)
        match_s = minimum(r[2] for r in runs)
        findings = last(runs)[3]
        append!(all_findings, [Finding(f.footgun, f.rule, "$(m)/$(f.file)", f.line, f.range, f.text) for f in findings])
        report[string(m)] = Dict("version" => string(pkgversion(m)), "files" => length(sources), "lines" => lines,
            "cold_seconds" => cold, "parse_seconds" => parse_s, "match_seconds" => match_s,
            "per_10k_lines_seconds" => (parse_s + match_s) * 1e4 / lines, "findings" => length(findings))
        println(rpad(string(m), 15), " lines=", lines, " cold=", round(cold; digits = 3), "s parse=", round(parse_s * 1e3; digits = 1),
            "ms match=", round(match_s * 1e3; digits = 1), "ms per10k=", round((parse_s + match_s) * 1e4 / lines * 1e3; digits = 1), "ms findings=", length(findings))
    end
    for f in all_findings
        println("F", f.footgun, " ", f.rule, " ", f.file, ":", f.line, "  ", f.text)
    end
    report["findings"] = [Dict("footgun" => f.footgun, "rule" => f.rule, "file" => f.file, "line" => f.line, "text" => f.text) for f in all_findings]
    isnothing(out) || write(out, JSON.json(report, 2))
    return nothing
end

main(isempty(ARGS) ? nothing : ARGS[1])
