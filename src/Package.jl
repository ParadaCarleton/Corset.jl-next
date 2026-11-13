"""
`package` stage: load target package into this process; collect package modules and method sites.

Environment must load package from its root (`Base.locate_package`); other environment is config error.
Load that throws becomes `load-error` finding, as `parse-error`.
"""
module Package

using ..Facts: Facts, PackageFacts, MethodSite, SyntaxFile, SyntaxNode, Finding, Label, Span, Precision, Confidence
using ..Config: ConfigError, parse_toml

"""Rule name load failures report under."""
const LOAD_ERROR = Symbol("load-error")

"""Level source load errors name; they always have level `deny`."""
const LOAD_SOURCE = "load check, always on"

"""Package identity from Project.toml at `root`; `nothing` for project without `name`."""
function package_id(root::String)::Union{Nothing, Base.PkgId}
    project = parse_toml(joinpath(root, "Project.toml"))
    haskey(project, "name") || return nothing
    name = project["name"]::String
    uuid = tryparse(Base.UUID, string(get(project, "uuid", "")))
    isnothing(uuid) && throw(ConfigError("package $name needs valid uuid in Project.toml"))
    return Base.PkgId(uuid, name)
end

"""Entry file of package `id` at `root`."""
entry_file(root::String, id::Base.PkgId)::String = joinpath(root, "src", "$(id.name).jl")

"""Package `id` loaded from `entry`; environment that loads package from other file is config error."""
function load_module(id::Base.PkgId, entry::String)::Module
    located = Base.locate_package(id)
    if isnothing(located) || realpath(located) != realpath(entry)
        where = isnothing(located) ? "cannot load $(id.name)" : "loads $(id.name) from $located"
        throw(ConfigError("environment $where; run Corset in environment that loads $entry"))
    end
    return Base.require(id)
end

"""`module` and its submodules defined inside it, depth first; root first."""
function module_tree(mod::Module)::Vector{Module}
    found = [mod]
    for name in names(mod; all = true)
        isdefined(mod, name) || continue
        inner = getglobal(mod, name)
        inner isa Module && inner !== mod && parentmodule(inner) === mod && append!(found, module_tree(inner))
    end
    return found
end

"""Package modules of loaded `root` module: its module tree, then trees of loaded extensions named in Project.toml."""
function package_modules(root::Module, project_root::String)::Vector{Module}
    extensions = keys(get(parse_toml(joinpath(project_root, "Project.toml")), "extensions", Dict{String, Any}()))
    loaded = filter(!isnothing, [Base.get_extension(root, Symbol(name)) for name in sort!(collect(extensions))])
    return reduce(vcat, map(module_tree, loaded); init = module_tree(root))
end

"""Whether Julia generated `method`: closure, keyword body or keyword sorter. Signatures there repeat user methods."""
function generated(method::Method)::Bool
    startswith(string(method.name), '#') && return true
    signature = Base.unwrap_unionall(method.sig)
    return !isempty(signature.parameters) && signature.parameters[1] === typeof(Core.kwcall)
end

"""Function name definition `node` writes, without module qualifier or quote: `+` for `Base.:+(a, b) = …`."""
function defined_name(file::SyntaxFile, node::SyntaxNode)::String
    text = Facts.source(file, Facts.definition_name(node))
    return lstrip(last(split(text, '.')), ':')
end

"""Byte where each line of `text` starts."""
line_starts(text::String)::Vector{Int} = [1; findall(==(UInt8('\n')), codeunits(text)) .+ 1]

"""Line index of one file: line starts, and function definition nodes by line where they start."""
struct Lines
    starts::Vector{Int}
    definitions::Dict{Int, Vector{SyntaxNode}}
end

function Lines(file::SyntaxFile)::Lines
    starts = line_starts(file.text)
    definitions = Dict{Int, Vector{SyntaxNode}}()
    for node in Facts.forms(file, "function")
        push!(get!(definitions, searchsortedlast(starts, first(Facts.trimmed_bytes(file.text, node))), SyntaxNode[]), node)
    end
    return Lines(starts, definitions)
end

"""Site of `method` in `file`: exact when one definition of its name starts on method line, line precision otherwise."""
function method_site(method::Method, file::SyntaxFile, lines::Lines)::MethodSite
    candidates = filter(node -> defined_name(file, node) == string(method.name), get(lines.definitions, method.line, SyntaxNode[]))
    length(candidates) == 1 && return MethodSite(method, file, only(candidates), Facts.span(file, only(candidates)))
    start = lines.starts[method.line]
    return MethodSite(method, file, nothing, Span(file.path, start, start, Precision.line))
end

"""Sites of methods `modules` define in `files`, sorted by file and position; generated methods left out."""
function method_sites(modules::Vector{Module}, files::Vector{SyntaxFile})::Vector{MethodSite}
    by_path = Dict(file.path => file for file in files)
    lines = Dict(file.path => Lines(file) for file in files)
    package = Set(modules)
    sites = MethodSite[]
    Base.visit(Core.methodtable) do method
        method.module in package && !generated(method) || return
        file = get(by_path, string(method.file), nothing)
        isnothing(file) || method.line > length(lines[file.path].starts) || push!(sites, method_site(method, file, lines[file.path]))
    end
    return sort!(sites; by = site -> (site.span.file, site.span.first_byte, string(site.method.sig)))
end

"""Exception `error` holds after load wrappers (`LoadError`, `InitError`) are removed."""
function unwrapped(error::Any)::Any
    while error isa LoadError || error isa InitError
        error = error.error
    end
    return error
end

"""
Exception and backtrace from including package `entry` into fresh anonymous module.
Precompilation runs in subprocess, so its error carries no frame inside package; this load shows them.
`nothing` when load succeeds here.
"""
function reproduce(entry::String)::Union{Nothing, Tuple{Any, Vector{Base.StackTraces.StackFrame}}}
    try
        Base.include(Module(), entry)
        return nothing
    catch error
        error isa InterruptException && rethrow()
        return error, stacktrace(catch_backtrace())
    end
end

"""
`load-error` finding for `error` with `frames`. Primary span: line of innermost frame in analyzed file; first line of
`entry` when none, or when entry is not analyzed.
"""
function load_error(error::Any, frames::Vector{Base.StackTraces.StackFrame}, entry::String, files::Vector{SyntaxFile})::Finding
    by_path = Dict(file.path => file for file in files)
    index = findfirst(frame -> haskey(by_path, string(frame.file)), frames)
    file, line = isnothing(index) ? (get(by_path, entry, nothing), 1) : (by_path[string(frames[index].file)], frames[index].line)
    starts = isnothing(file) ? [1] : line_starts(file.text)
    path, start = isnothing(file) ? (entry, 1) : (file.path, starts[clamp(line, 1, length(starts))])
    message = first(split(sprint(showerror, unwrapped(error)), '\n'))
    return Finding(
        LOAD_ERROR, :load_error, Confidence.definite, "package does not load", Label(Span(path, start, start, Precision.line), message),
        Label[], "Julia cannot load package; rules after `syntax` stage did not run", Facts.manual_fix("fix error at marked line"),
    )
end

"""
Facts of package `id` at `root`, loaded in this process, with method sites in `files`; `load-error` finding when load throws.
Precompile failure carries no frame inside package, so error comes from second load in anonymous module (`reproduce`).
"""
function load(root::String, id::Base.PkgId, files::Vector{SyntaxFile})::Union{PackageFacts, Finding}
    entry = entry_file(root, id)
    mod = try
        load_module(id, entry)
    catch error
        error isa ConfigError && rethrow()
        frames = stacktrace(catch_backtrace())
        if error isa Base.Precompilation.PkgPrecompileError
            again = reproduce(entry)
            isnothing(again) || ((error, frames) = again)
        end
        return load_error(error, frames, entry, files)
    end
    modules = package_modules(mod, root)
    return PackageFacts(id.name, id.uuid, root, modules, method_sites(modules, files))
end

end
