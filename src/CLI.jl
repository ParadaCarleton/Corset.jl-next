"""
Command line: `corset check | fix | baseline | explain`.

Exit codes follow Cargo: 0 pass, 1 failing finding, 2 usage or config error, 101 internal error.
Level flags work as in rustc: `-A`, `-W`, `-D` take group or rule name and apply in order; `-D warnings` fails on warnings.
"""
module CLI

using ArgParse: ArgParseSettings, ArgParseError, @add_arg_table!, parse_args
using JSON: JSON
using ..Facts: Confidence, Tier
using ..Config: ConfigError, Flags, Kind, Level
using ..Rules: Rules
using ..Engine: Engine, Report, Analysis
using ..Config: Settings
using ..Cache: Cache
using ..Render: render_all, render_summary, render_coverage
using ..Output: json_report, sarif_report
using ..OptOuts: OptOuts
using ..Baseline: Baseline
using ..Syntax: Syntax
using ..Package: Package
using ..Launch: Launch

const EXIT_PASS = 0
const EXIT_FAIL = 1
const EXIT_USAGE = 2
const EXIT_INTERNAL = 101
"""Relaunched `fix` edited files of loaded package; relaunching process checks them in fresh process. Never user-facing."""
const EXIT_RECHECK = 3

"""Bad command line that ArgParse cannot catch, such as path that does not exist."""
struct UsageError <: Exception
    message::String
end

Base.showerror(io::IO, error::UsageError)::Nothing = print(io, error.message)

"""Level each level flag sets."""
const LEVEL_FLAGS = Dict(
    "-A" => Level.allow, "--allow" => Level.allow, "-W" => Level.warn, "--warn" => Level.warn, "-D" => Level.deny, "--deny" => Level.deny,
)

"""Text `corset explain` prints for checks that are not registry rules."""
const BUILTIN_DOCS = Dict(
    String(OptOuts.NAME) => "opt-out (always on)\n\nReports malformed opt-out comments, missing reasons, unknown rules, late `allow-file`, and opt-outs that suppress nothing.",
    String(Syntax.PARSE_ERROR) => "parse-error (always on)\n\nReports code JuliaSyntax cannot parse. Rules still run on recovered tree; no level, opt-out or baseline hides parse error.",
    String(Package.LOAD_ERROR) => "load-error (always on)\n\nReports package or extension that throws while loading. Failed package: rules after `syntax` stage do not run. No level, opt-out or baseline hides load error.",
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
        if level == Level.deny && name == "warnings"
            deny_warnings = true
        else
            push!(levels, name => level)
        end
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
            "--kind"
            help = "project kind: library, application or script"
            range_tester = in(["library", "application", "script"])
            "--format"
            help = "output format: text, json or sarif"
            default = "text"
            range_tester = in(["text", "json", "sarif"])
            "--no-cache"
            help = "analyze again; read and write no cached analysis"
            action = :store_true
            "--effects"
            help = "run effects stage without an effects rule; collect library summaries"
            action = :store_true
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
(enum_option(::Type{T}, options::Dict{String, Any}, name::String)::Union{Nothing, T}) where {T <: Enum} =
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

"""Write `report` to `out` in `format`. Rendering targets buffer, so precompiled code serves every stream type."""
function write_report(out::IO, report::Report, format::String)::Nothing
    buffer = IOBuffer()
    if format == "text"
        render_all(buffer, report)
        render_summary(buffer, report)
        render_coverage(buffer, report)
    else
        data = format == "json" ? json_report(report) : sarif_report(report, string(pkgversion(Base.moduleroot(@__MODULE__))))
        # Barrier keeps JSON writer out of this method's inference, so packages that target loads cannot invalidate it.
        println(buffer, Base.inferencebarrier(JSON.json)(data; pretty = true)::String)
    end
    write(out, take!(buffer))
    return nothing
end

"""
Arguments of `check` that runs after `fix` with `args`: command name changes, and `--tier` drops, since `check` rejects it.
Command name comes before path, and no option value is `fix`.
"""
function recheck_arguments(args::Vector{String})::Vector{String}
    checked = replace(args, "fix" => "check"; count = 1)
    at = findfirst(==("--tier"), checked)
    isnothing(at) || deleteat!(checked, at:(at + 1))
    return filter!(arg -> !startswith(arg, "--tier="), checked)
end

"""Exit code of finished relaunched `process`; signal that ended it is internal error."""
exit_code(process::Base.Process)::Int = process.termsignal == 0 ? process.exitcode : EXIT_INTERNAL

"""Finish `command` on `analyzed` under `settings`: write baseline, or write report to `out` in `format`. Return exit code."""
function finish(command::String, settings::Settings, analyzed::Analysis, @nospecialize(out::IO), @nospecialize(err::IO), format::String)::Int
    if command == "baseline"
        println(err, "corset: wrote ", Engine.baseline(analyzed), " findings to ", Baseline.FILE)
        return EXIT_PASS
    end
    report = Engine.report(settings, analyzed)
    write_report(out, report, format)
    return Engine.failed(report) ? EXIT_FAIL : EXIT_PASS
end

"""
Run command line `args`: report to `out`, messages to `err`. Return exit code. `cache` directory holds analyses;
`nothing` or `--no-cache` turns cache off.

With `launch`, run that loads package builds temporary environment and runs again in new Julia process there,
unless cache holds analysis for that process; native abort reruns it (`Launch.supervise`). Without `launch`, current
environment must load package from its root: relaunched process and tests. Relaunched process gets crash `journal`.
"""
function execute(args::Vector{String}, @nospecialize(out::IO), @nospecialize(err::IO); launch::Bool, cache::Union{Nothing, String}, journal::Union{Nothing, String} = nothing)::Int
    try
        levels, deny_warnings, rest = level_flags(args)
        parsed = parse_args(rest, argument_settings())
        isnothing(parsed) && return EXIT_PASS
        haskey(parsed, "%COMMAND%") || throw(UsageError("give command: check, fix, baseline or explain"))
        command = parsed["%COMMAND%"]
        options = parsed[command]
        command == "explain" && return explain(out, options["rule"])
        # Concrete type keeps string methods of other packages from invalidating this code.
        path = options["path"]::String
        ispath(path) || throw(UsageError("no such file or directory: $path"))
        flags = Flags(; levels, deny_warnings, effects = options["effects"], kind = enum_option(Kind.T, options, "kind"), confidence = enum_option(Confidence.T, options, "confidence"), tier = enum_option(Tier.T, options, "tier"))
        cache = options["no-cache"] ? nothing : cache
        target = launch ? Engine.load_target(path, flags) : nothing
        if !isnothing(target)
            env = Launch.environment(target, err)
            # Fix writes files and checks again, so it always runs in relaunched process.
            stored = command == "fix" || isnothing(cache) ? nothing : Engine.cached(path, flags, cache, Launch.load_path(env))
            isnothing(stored) || return finish(command, stored..., out, err, options["format"])
            code = exit_code(Launch.supervise(env, args, cache, out, err, Launch.CRASHES))
            code == EXIT_RECHECK || return code
            return exit_code(Launch.supervise(env, recheck_arguments(args), cache, out, err, Launch.CRASHES))
        end
        isnothing(cache) || !Cache.cold(cache, realpath(path)) || println(err, "corset: no cached analysis of ", path, "; first run can be slow, later runs reuse it")
        if command == "fix"
            count, stale = Engine.fix!(path; flags, cache, journal)
            println(err, "corset: applied ", count, " edits")
            # Process loaded package before edits, so its methods are stale; only relaunched child gets here.
            if stale
                launch && error("fix loaded package without relaunch")
                return EXIT_RECHECK
            end
        end
        return finish(command, Engine.analysis(path, flags, cache, journal)..., out, err, options["format"])
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
