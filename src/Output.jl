"""Machine-readable reports: Corset JSON and SARIF 2.1.0. Columns count code points; byte offsets are exact."""
module Output

using ..Facts: Finding, Label, Fix
using ..Config: Level
using ..Rules: REGISTRY
using ..Engine: Diagnostic, Report
using ..Render: position
using ..Baseline: Baseline

"""Report format version of Corset JSON."""
const JSON_VERSION = 1

"""Location of `label` as plain data: file, start and end positions (end exclusive), bytes, precision and text."""
function label_data(report::Report, label::Label, primary::Bool)::Dict{String, Any}
    span = label.span
    text = report.sources[span.file]
    line, column = position(text, span.first_byte)
    end_line, end_column = position(text, span.last_byte + 1)
    return Dict(
        "file" => relpath(span.file, report.root), "line" => line, "column" => column, "end_line" => end_line,
        "end_column" => end_column, "first_byte" => span.first_byte, "last_byte" => span.last_byte,
        "precision" => string(span.precision), "text" => label.text, "primary" => primary,
    )
end

"""Fix of finding as plain data; `nothing` without fix."""
fix_data(report::Report, fix::Union{Nothing, Fix})::Union{Nothing, Dict{String, Any}} = isnothing(fix) ? nothing : Dict(
        "text" => fix.text, "tier" => string(fix.tier),
        "edits" => [
            Dict("file" => relpath(edit.span.file, report.root), "first_byte" => edit.span.first_byte, "last_byte" => edit.span.last_byte, "replacement" => edit.replacement)
            for edit in fix.edits
        ],
    )

"""Corset JSON report: one entry per diagnostic, baselined count and stale baseline entries."""
function json_report(report::Report)::Dict{String, Any}
    diagnostics = map(report.diagnostics) do diagnostic
        finding = diagnostic.finding
        return Dict(
            "rule" => string(finding.rule), "kind" => string(finding.kind), "level" => string(diagnostic.level),
            "level_source" => diagnostic.source, "confidence" => string(finding.confidence), "message" => finding.message,
            "why" => finding.why, "labels" => [label_data(report, finding.primary, true); [label_data(report, cause, false) for cause in finding.causes]],
            "fix" => fix_data(report, finding.fix),
        )
    end
    stale = [Dict("rule" => key.rule, "file" => key.file, "definition" => key.definition) for key in report.stale]
    blind_spots = map(report.blind_spots) do spot
        location = filter(pair -> first(pair) ∉ ("text", "primary"), label_data(report, Label(spot.span, spot.cause), true))
        return merge(location, Dict("cause" => spot.cause))
    end
    coverage = Dict("files" => length(report.sources), "blind_spots" => blind_spots)
    return Dict("version" => JSON_VERSION, "diagnostics" => diagnostics, "baselined" => report.baselined, "stale" => stale, "coverage" => coverage)
end

"""SARIF physical location of `label`."""
function sarif_location(report::Report, label::Label)::Dict{String, Any}
    data = label_data(report, label, true)
    region = Dict(
        "startLine" => data["line"], "startColumn" => data["column"], "endLine" => data["end_line"], "endColumn" => data["end_column"],
        "byteOffset" => label.span.first_byte - 1, "byteLength" => label.span.last_byte - label.span.first_byte + 1,
    )
    return Dict("physicalLocation" => Dict("artifactLocation" => Dict("uri" => data["file"]), "region" => region))
end

"""SARIF fixes of `finding`: one artifact change per edited file."""
function sarif_fixes(report::Report, finding::Finding)::Vector{Dict{String, Any}}
    (isnothing(finding.fix) || isempty(finding.fix.edits)) && return Dict{String, Any}[]
    files = unique(edit.span.file for edit in finding.fix.edits)
    changes = map(files) do file
        replacements = [
            Dict(
                "deletedRegion" => Dict("byteOffset" => edit.span.first_byte - 1, "byteLength" => edit.span.last_byte - edit.span.first_byte + 1),
                "insertedContent" => Dict("text" => edit.replacement),
            ) for edit in finding.fix.edits if edit.span.file == file
        ]
        return Dict("artifactLocation" => Dict("uri" => relpath(file, report.root)), "replacements" => replacements)
    end
    return [Dict("description" => Dict("text" => finding.fix.text), "artifactChanges" => changes)]
end

"""SARIF result for `diagnostic`."""
function sarif_result(report::Report, diagnostic::Diagnostic)::Dict{String, Any}
    finding = diagnostic.finding
    related = [merge(sarif_location(report, cause), Dict("id" => index, "message" => Dict("text" => cause.text))) for (index, cause) in enumerate(finding.causes)]
    return Dict(
        "ruleId" => string(finding.rule), "level" => diagnostic.level == Level.deny ? "error" : "warning",
        "message" => Dict("text" => "$(finding.message): $(finding.why)"), "locations" => [sarif_location(report, finding.primary)],
        "relatedLocations" => related, "fixes" => sarif_fixes(report, finding),
    )
end

"""SARIF result for baseline entry no finding matches."""
stale_result(key::Baseline.Key)::Dict{String, Any} = Dict(
    "ruleId" => "baseline", "level" => "error",
    "message" => Dict("text" => "baseline entry for `$(key.rule)` in $(key.file) matches no finding; run `corset baseline`"),
    "locations" => [Dict("physicalLocation" => Dict("artifactLocation" => Dict("uri" => Baseline.FILE)))],
)

"""SARIF 2.1.0 log of `report`, produced by Corset `version`."""
function sarif_report(report::Report, version::String)::Dict{String, Any}
    groups = Dict(string(entry.name) => string(entry.group) for entry in REGISTRY)
    names = sort!(unique([[string(diagnostic.finding.rule) for diagnostic in report.diagnostics]; isempty(report.stale) ? String[] : ["baseline"]]))
    rules = [Dict("id" => name, "properties" => Dict("group" => get(groups, name, "correctness"))) for name in names]
    driver = Dict("name" => "Corset", "informationUri" => "https://github.com/ParadaCarleton/Corset.jl", "version" => version, "rules" => rules)
    results = [[sarif_result(report, diagnostic) for diagnostic in report.diagnostics]; [stale_result(key) for key in report.stale]]
    notifications = [
        Dict("level" => "note", "message" => Dict("text" => "skipped: $(spot.cause)"), "locations" => [sarif_location(report, Label(spot.span, spot.cause))])
            for spot in report.blind_spots
    ]
    invocation = Dict("executionSuccessful" => true, "toolExecutionNotifications" => notifications)
    run = Dict("tool" => Dict("driver" => driver), "columnKind" => "unicodeCodePoints", "results" => results, "invocations" => [invocation])
    return Dict("\$schema" => "https://json.schemastore.org/sarif-2.1.0.json", "version" => "2.1.0", "runs" => [run])
end

end
