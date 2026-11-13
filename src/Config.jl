"""
Run settings: project kind, levels, confidence, fix tier and project bans.

Sources, later wins: kind preset, `[preferences.Corset]` in Project.toml, `[Corset]` in LocalPreferences.toml,
command-line flags. Rule level beats group level.
"""
module Config

using Configurations: @option, from_dict
using EnumX: @enumx
using TOML: TOML
using ..Facts: Facts, Group, Confidence, Tier, RuleEntry, Ban

"""Lint level, as in Clippy: `deny` findings fail run; `allow` findings are not reported."""
@enumx Level allow warn deny

"""Project kind: who uses code. Kind picks enabled groups and fix tier."""
@enumx Kind library application script

"""Bad config file or flag. Command line exits with code 2."""
struct ConfigError <: Exception
    message::String
end

Base.showerror(io::IO, error::ConfigError)::Nothing = print(io, "config error: ", error.message)

"""One `banned` entry as written: Argus `pattern` or binding `name` regex, and `reason`."""
@option struct BanTable
    pattern::Union{Nothing, String} = nothing
    name::Union{Nothing, String} = nothing
    reason::String
end

"""One preferences table as written. `nothing` marks key left out, so later table overlays earlier one key by key."""
@option struct Table
    kind::Union{Nothing, String} = nothing
    confidence::Union{Nothing, String} = nothing
    fix_tier::Union{Nothing, String} = nothing
    levels::Dict{String, String} = Dict{String, String}()
    banned::Union{Nothing, Vector{BanTable}} = nothing
end

"""Command-line settings; each beats config file value."""
@kwdef struct Flags
    levels::Vector{Pair{String, Level.T}} = Pair{String, Level.T}[]
    confidence::Union{Nothing, Confidence.T} = nothing
    tier::Union{Nothing, Tier.T} = nothing
    deny_warnings::Bool = false
end

"""Resolved settings for one run. `levels` maps group or rule name to level and where it was set."""
struct Settings
    kind::Kind.T
    confidence::Confidence.T
    tier::Tier.T
    levels::Dict{String, Tuple{Level.T, String}}
    deny_warnings::Bool
    bans::Vector{Ban}
end

"""Groups each kind enables, and highest fix tier it applies."""
const PRESETS = Dict(
    Kind.library => (Set(instances(Group.T)), Tier.likely),
    Kind.application => (Set([Group.correctness, Group.performance, Group.readability]), Tier.breaking),
    Kind.script => (Set([Group.correctness, Group.readability]), Tier.breaking),
)

"""Level `kind` preset gives `group`: correctness `deny`, other enabled groups `warn`, rest `allow`."""
function preset_level(kind::Kind.T, group::Group.T)::Level.T
    group in first(PRESETS[kind]) || return Level.allow
    return group == Group.correctness ? Level.deny : Level.warn
end

"""Parsed TOML `file`; syntax error becomes config error."""
function parse_toml(file::String)::Dict{String, Any}
    try
        return TOML.parsefile(file)
    catch error
        error isa TOML.ParserError || rethrow()
        throw(ConfigError("$file: $(sprint(showerror, error))"))
    end
end

"""Table under `keys` in TOML `file`; empty table when file or table is missing."""
function read_table(file::String, keys::Tuple{Vararg{String}})::Table
    isfile(file) || return Table()
    data = parse_toml(file)
    for key in keys
        data = get(data, key, nothing)
        data isa AbstractDict || return Table()
    end
    try
        return from_dict(Table, data)
    catch error
        throw(ConfigError("$file: $(sprint(showerror, error))"))
    end
end

"""Table `under` with every key `over` sets replaced; `levels` merge name by name, `banned` list replaces whole list."""
overlay(under::Table, over::Table)::Table = Table(;
    kind = something(over.kind, under.kind, Some(nothing)),
    confidence = something(over.confidence, under.confidence, Some(nothing)),
    fix_tier = something(over.fix_tier, under.fix_tier, Some(nothing)),
    levels = merge(under.levels, over.levels),
    banned = something(over.banned, under.banned, Some(nothing)),
)

"""Ban from `entry`: exactly one of `pattern` and `name`, and reason with text. Bad entry is config error."""
function ban(entry::BanTable)::Ban
    xor(isnothing(entry.pattern), isnothing(entry.name)) || throw(ConfigError("banned entry needs exactly one of `pattern` and `name`"))
    isempty(strip(entry.reason)) && throw(ConfigError("banned entry needs reason"))
    isnothing(entry.name) || return Ban(entry.name, name_regex(entry.name), entry.reason)
    try
        return Ban(entry.pattern, Facts.parse_pattern(entry.pattern), entry.reason)
    catch error
        error isa ArgumentError || rethrow()
        throw(ConfigError("banned pattern $(repr(entry.pattern)): $(error.msg)"))
    end
end

"""Regex that matches whole binding name `text`; bad regex is config error, unbalanced one included."""
function name_regex(text::String)::Regex
    try
        # Compile alone first: `a)|(b` would close anchoring group and match any name starting with `a`.
        Regex(text)
        return Regex("^(?:$text)\$")
    catch error
        error isa ErrorException || rethrow()
        throw(ConfigError("banned name $(repr(text)): $(error.msg)"))
    end
end

"""Bans of `table`; table without `banned` key bans nothing."""
bans(table::Table)::Vector{Ban} = map(ban, something(table.banned, BanTable[]))

"""Value of enum `T` named `name`; error names config `key` and valid choices."""
function parse_enum(::Type{T}, name::String, key::String)::T where {T <: Enum}
    index = findfirst(value -> string(value) == name, instances(T))
    isnothing(index) && throw(ConfigError("$key is $(repr(name)); choose one of $(join(string.(instances(T)), ", "))"))
    return instances(T)[index]
end

"""Kind from `setting`; without setting, `script` outside any project and `application` for nameless project."""
function project_kind(setting::Union{Nothing, String}, project::Union{Nothing, Dict{String, Any}})::Kind.T
    isnothing(setting) || return parse_enum(Kind.T, setting, "kind")
    isnothing(project) && return Kind.script
    haskey(project, "name") || return Kind.application
    throw(ConfigError("package needs kind in [preferences.Corset]: \"library\" or \"application\""))
end

"""Directory of nearest Project.toml at or above `path`; `nothing` when no project encloses it."""
function project_root(path::String)::Union{Nothing, String}
    directory = abspath(isdir(path) ? path : dirname(abspath(path)))
    while !isfile(joinpath(directory, "Project.toml"))
        parent = dirname(directory)
        parent == directory && return nothing
        directory = parent
    end
    return directory
end

"""Config table of project at `root`: Project.toml table overlaid by LocalPreferences.toml table."""
project_table(root::String)::Table = overlay(
    read_table(joinpath(root, "Project.toml"), ("preferences", "Corset")),
    read_table(joinpath(root, "LocalPreferences.toml"), ("Corset",)),
)

"""Settings for project at `root` (`nothing` outside any project) and command-line `flags`; level names must name group or rule in `rules`."""
function settings(root::Union{Nothing, String}, flags::Flags, rules::Vector{RuleEntry})::Settings
    project = isnothing(root) ? nothing : parse_toml(joinpath(root, "Project.toml"))
    table = isnothing(root) ? Table() : project_table(root)
    kind = project_kind(table.kind, project)
    names = Set([map(string, collect(instances(Group.T))); [string(entry.name) for entry in rules]])
    levels = Dict{String, Tuple{Level.T, String}}()
    written = [name => parse_enum(Level.T, level, "levels.$name") for (name, level) in table.levels]
    for (source, pairs) in ("config" => written, "command line" => flags.levels), (name, level) in pairs
        name in names || throw(ConfigError("$source level names no rule or group: $(repr(name))"))
        levels[name] = (level, source)
    end
    confidence = something(flags.confidence, isnothing(table.confidence) ? Confidence.definite : parse_enum(Confidence.T, table.confidence, "confidence"))
    tier = something(flags.tier, isnothing(table.fix_tier) ? last(PRESETS[kind]) : parse_enum(Tier.T, table.fix_tier, "fix_tier"))
    return Settings(kind, confidence, tier, levels, flags.deny_warnings, bans(table))
end

"""Level of `entry` under `settings`, and where it was set. Rule setting beats group setting; group setting beats preset."""
function level_of(settings::Settings, entry::RuleEntry)::Tuple{Level.T, String}
    rule, group = string(entry.name), string(entry.group)
    haskey(settings.levels, rule) && return settings.levels[rule][1], "`$rule` set in $(settings.levels[rule][2])"
    haskey(settings.levels, group) && return settings.levels[group][1], "$group group set in $(settings.levels[group][2])"
    return preset_level(settings.kind, entry.group), "$group group, $(settings.kind) preset"
end

end
