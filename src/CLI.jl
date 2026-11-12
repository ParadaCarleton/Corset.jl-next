"""
Command line: `corset check | fix | baseline | explain`.

Exit codes follow Cargo: 0 pass, 1 failing finding, 2 usage or config error, 101 internal error.
Level flags work as in rustc: `-A`, `-W`, `-D` take group or rule name and apply in order; `-D warnings` fails on warnings.
"""
module CLI

using ArgParse: ArgParseSettings, ArgParseError, @add_arg_table!, parse_args
using JSON: JSON
using ..Facts: Confidence, Tier
using ..Config: ConfigError, Flags, Level
using ..Rules: Rules
using ..Engine: Engine, Report
using ..Render: render_all, render_summary
using ..Output: json_report, sarif_report
using ..OptOuts: OptOuts
using ..Baseline: Baseline

const EXIT_PASS = 0
const EXIT_FAIL = 1
const EXIT_USAGE = 2
const EXIT_INTERNAL = 101

"""Bad command line that ArgParse cannot catch, such as path that does not exist."""
struct UsageError <: Exception
    message::String
end

Base.showerror(io::IO, error::UsageError) = print(io, error.message)

"""Level each level flag sets."""
const LEVEL_FLAGS = Dict(
    "-A" => Level.allow, "--allow" => Level.allow, "-W" => Level.warn, "--warn" => Level.warn, "-D" => Level.deny, "--deny" => Level.deny,
)

"""Text `corset explain` prints for checks that are not registry rules."""
const BUILTIN_DOCS = Dict(
    String(OptOuts.NAME) => "opt-out (always on)\n\nReports malformed opt-out comments, missing reasons, unknown rules, late `allow-file`, and opt-outs that suppress nothing.",
    "baseline" => "baseline (always on)\n\nReports `$(Baseline.FILE)` entries that match no finding. Run `corset baseline` to rewrite file.",
)

"""Level flags of `args` in order, whether `-D warnings` appears, and remaining arguments."""
function level_flags(args::Vector{String})::Tuple{Vector{Pair{String, Level.T}}, Bool, Vector{String}}
    levels, deny_warnings, rest = Pair{String, Level.T}[], false, String[]
    index = 1
    while index <= length(args)
        level = get(LEVEL_FLAGS, args[index], nothing)
        if isnothing(level)
            push!(rest, args[index])
            index += 1
            continue
        end
        index < length(args) || throw(ArgParseError("$(args[index]) needs group or rule name"))
        name = args[index + 1]
        level == Level.deny && name == "warnings" ? (deny_warnings = true) : push!(levels, name => level)
        index += 2
    end
    return levels, deny_warnings, rest
end

"""ArgParse settings for every command; errors throw so `execute` maps them to exit code 2."""
function argument_settings()::ArgParseSettings
    settings = ArgParseSettings(;
        prog = "corset", description = "Julia code-quality checker. Level flags: -A, -W, -D <group or rule>; -D warnings fails on warnings.",
        exc_handler = (_, error) -> throw(error), exit_after_help = false,
    )
    @add_arg_table! settings begin
        "check"
        help = "report findings"
        action = :command
        "fix"
        help = "apply fixes up to fix tier, then report what remains"
        action = :command
        "baseline"
        help = "write current findings to $(Baseline.FILE)"
        action = :command
        "explain"
        help = "print rule documentation"
        action = :command
    end
    for command in ("check", "fix", "baseline")
        @add_arg_table! settings[command] begin
            "path"
            help = "file or directory to check"
            default = "."
            "--confidence"
            help = "lowest confidence to report: definite or possible"
            range_tester = in(["definite", "possible"])
            "--format"
            help = "output format: text, json or sarif"
            default = "text"
            range_tester = in(["text", "json", "sarif"])
        end
    end
    @add_arg_table! settings["fix"] begin
        "--tier"
        help = "highest fix tier to apply: safe, likely or breaking"
        range_tester = in(["safe", "likely", "breaking"])
    end
    @add_arg_table! settings["explain"] begin
        "rule"
        help = "rule name"
        required = true
    end
    return settings
end

"""Enum value of `T` named by option `name` in `options`; `nothing` when option is absent."""
enum_option(::Type{T}, options::Dict{String, Any}, name::String) where {T <: Enum} =
    isnothing(get(options, name, nothing)) ? nothing : only(filter(value -> string(value) == options[name], collect(instances(T))))

"""Docstring text of module `mod`, read from docsystem metadata; every rule module has one (test enforces)."""
function module_doc(mod::Module)::String
    docs = Base.Docs.meta(mod)[Base.Docs.Binding(mod, nameof(mod))].docs
    return join((join(docstring.text) for docstring in values(docs)), "\n")
end

"""Write documentation of rule `name` to `out`."""
function explain(out::IO, name::String)::Int
    haskey(BUILTIN_DOCS, name) && (println(out, BUILTIN_DOCS[name]); return EXIT_PASS)
    index = findfirst(entry -> string(entry.name) == name, Rules.REGISTRY)
    isnothing(index) && throw(UsageError("no rule named $(repr(name))"))
    entry = Rules.REGISTRY[index]
    footguns = join(("F$id" for id in entry.footguns), ", ")
    println(out, name, " (", entry.group, " group, ", entry.stage, " stage, ", footguns, ")\n")
    println(out, strip(module_doc(parentmodule(entry.run))))
    return EXIT_PASS
end

"""Write `report` to `out` in `format`."""
function write_report(out::IO, report::Report, format::String)::Nothing
    if format == "text"
        render_all(out, report)
        render_summary(out, report)
    else
        data = format == "json" ? json_report(report) : sarif_report(report, string(pkgversion(Base.moduleroot(@__MODULE__))))
        println(out, JSON.json(data; pretty = true))
    end
    return nothing
end

"""Run command line `args`: report to `out`, messages to `err`. Return exit code."""
function execute(args::Vector{String}, out::IO, err::IO)::Int
    try
        levels, deny_warnings, rest = level_flags(args)
        parsed = parse_args(rest, argument_settings())
        isnothing(parsed) && return EXIT_PASS
        haskey(parsed, "%COMMAND%") || throw(UsageError("give command: check, fix, baseline or explain"))
        command = parsed["%COMMAND%"]
        options = parsed[command]
        command == "explain" && return explain(out, options["rule"])
        path = options["path"]
        ispath(path) || throw(UsageError("no such file or directory: $path"))
        flags = Flags(; levels, deny_warnings, confidence = enum_option(Confidence.T, options, "confidence"), tier = enum_option(Tier.T, options, "tier"))
        if command == "baseline"
            println(err, "corset: wrote ", Engine.baseline(path; flags), " findings to ", Baseline.FILE)
            return EXIT_PASS
        end
        command == "fix" && println(err, "corset: applied ", Engine.fix!(path; flags), " edits")
        report = Engine.check(path; flags)
        write_report(out, report, options["format"])
        return Engine.failed(report) ? EXIT_FAIL : EXIT_PASS
    catch error
        if error isa ArgParseError || error isa ConfigError || error isa UsageError
            println(err, "corset: ", sprint(showerror, error))
            return EXIT_USAGE
        end
        println(err, "corset: internal error: ", sprint(showerror, error, catch_backtrace()))
        return EXIT_INTERNAL
    end
end

end
