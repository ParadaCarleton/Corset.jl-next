"""
`package` stage: load target package into this process; collect package modules, public values, method sites and struct sites.

Environment must load package from its root (`Base.locate_package`); other environment is config error.
Load that throws becomes `load-error` finding, as `parse-error`.
Each extension whose triggers environment can load gets them loaded; extension that throws gets `load-error` finding.
"""
module Package

using ..Facts: Facts, line_starts, PackageFacts, ProjectFacts, MethodSite, StructSite, SyntaxFile, SyntaxNode, Finding, Label, Span, Precision, Confidence, BlindSpot
using ..Config: ConfigError, parse_toml

"""Rule name load failures report under."""
const LOAD_ERROR = Symbol("load-error")

"""Level source load errors name; they always have level `deny`."""
const LOAD_SOURCE = "load check, always on"

"""Package identity of `project`; project without valid uuid is config error, since Julia loads package by uuid."""
function package_id(project::ProjectFacts)::Base.PkgId
    isnothing(project.uuid) && throw(ConfigError("package $(project.name) needs valid uuid in Project.toml"))
    return Base.PkgId(project.uuid, project.name)
end

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

"""Package modules of loaded `root` module: its module tree, then trees of loaded extensions of `project`."""
function package_modules(root::Module, project::ProjectFacts)::Vector{Module}
    loaded = filter(!isnothing, [Base.get_extension(root, Symbol(extension.name)) for extension in project.extensions])
    return reduce(vcat, map(module_tree, loaded); init = module_tree(root))
end

"""
Values public names reach: names root module, first of package `modules`, exports or declares `public`, then public
names of package submodules those names reach.
"""
function public_values(modules::Vector{Module})::Base.IdSet{Any}
    package, queue = Set(modules), [first(modules)]
    reached, found = Set(queue), Base.IdSet{Any}()
    while !isempty(queue)
        mod = pop!(queue)
        for name in names(mod)
            isdefined(mod, name) || continue
            binding = getglobal(mod, name)
            push!(found, binding)
            if binding isa Module && binding in package && !(binding in reached)
                push!(reached, binding)
                push!(queue, binding)
            end
        end
    end
    return found
end

"""Whether Julia generated `method`: closure, keyword body or keyword sorter. Signatures there repeat user methods."""
function generated(method::Method)::Bool
    startswith(string(method.name), '#') && return true
    signature = Base.unwrap_unionall(method.sig)
    return !isempty(signature.parameters) && signature.parameters[1] === typeof(Core.kwcall)
end

"""Name `text` spells, without module qualifier, quote or parentheses: `==` for `Base.:(==)`."""
unqualified(text::AbstractString)::String = strip(lstrip(last(split(text, '.')), ':'), ['(', ')'])

"""Function name definition `node` writes, without module qualifier, quote or parentheses: `==` for `Base.:(==)(a, b) = …`."""
defined_name(file::SyntaxFile, node::SyntaxNode)::String = unqualified(Facts.source(file, Facts.definition_name(node)))

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

"""Name `method` has in source: `f` for keyword body `#f#3` Julia makes from `f`; Julia name otherwise."""
function source_name(method::Method)::String
    name = string(method.name)
    body = match(r"^#([^#]+)#\d+$", name)
    return isnothing(body) ? name : body[1]
end

"""Site of `method` in `file`: exact when one definition of its source name starts on method line, line precision otherwise."""
function method_site(method::Method, file::SyntaxFile, lines::Lines)::MethodSite
    candidates = filter(node -> defined_name(file, node) == source_name(method), get(lines.definitions, method.line, SyntaxNode[]))
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
    return sort!(sites; lt = site_before)
end

"""
Whether `site` sorts before `other`: by file, then position. Printed signature breaks ties between methods of one
definition; printing type searches loaded modules for alias, so it runs only on ties.
"""
function site_before(site::MethodSite, other::MethodSite)::Bool
    place, other_place = (site.span.file, site.span.first_byte), (other.span.file, other.span.first_byte)
    return place == other_place ? isless(string(site.method.sig), string(other.method.sig)) : isless(place, other_place)
end

"""Type name of struct that constructor `method` builds; `nothing` for other method."""
function constructed(method::Method)::Union{Nothing, Core.TypeName}
    callee = Base.unwrap_unionall(Facts.tuple_parameters(method.sig)[1])
    Base.isType(callee) || return nothing
    target = Base.unwrap_unionall(callee.parameters[1])
    return target isa DataType ? target.name : nothing
end

"""
Sites of structs that constructor method `sites` tie to `struct` forms in `files`.
Default constructors start on first field line, or on struct line for struct without fields; inner constructors start
in body. So constructor of same name that starts between line start of form and its end builds its type.
"""
function struct_sites(sites::Vector{MethodSite}, files::Vector{SyntaxFile})::Vector{StructSite}
    built = Dict{String, Vector{Tuple{Int, Core.TypeName}}}()
    for site in sites
        name = constructed(site.method)
        isnothing(name) || push!(get!(built, site.span.file, Tuple{Int, Core.TypeName}[]), (site.span.first_byte, name))
    end
    found = StructSite[]
    for file in files
        starts, constructors = line_starts(file.text), get(built, file.path, Tuple{Int, Core.TypeName}[])
        for node in Facts.forms(file, "struct")
            bytes = Facts.trimmed_bytes(file.text, node)
            lines, name = starts[searchsortedlast(starts, first(bytes))]:last(bytes), Symbol(Facts.source(file, Facts.definition_name(node)))
            index = findfirst(((byte, type),) -> byte in lines && type.name === name, constructors)
            isnothing(index) || push!(found, StructSite(last(constructors[index]).wrapper, file, node))
        end
    end
    return found
end

"""
Pairs (earlier, later) of `sites` where later definition replaced earlier one with same signature.
Julia keeps replaced method in method table with `dispatch_status` 0 and numbers definitions by `primary_world`.
"""
function overwrites(sites::Vector{MethodSite})::Vector{Tuple{MethodSite, MethodSite}}
    ordered = sort(sites; by = site -> site.method.primary_world)
    found = Tuple{MethodSite, MethodSite}[]
    for (index, earlier) in enumerate(ordered)
        earlier.method.dispatch_status == 0 || continue
        later = findnext(site -> site.method.sig == earlier.method.sig, ordered, index + 1)
        isnothing(later) || push!(found, (earlier, ordered[later]))
    end
    return sort!(found; by = pair -> (last(pair).span.file, last(pair).span.first_byte))
end

"""Exception `error` holds after load wrappers (`LoadError`, `InitError`) are removed."""
function unwrapped(error::Any)::Any
    while error isa LoadError || error isa InitError
        error = error.error
    end
    return error
end

"""
Exception and backtrace from including `entry` again, into fresh anonymous module that carries uuid of package `id`.
Precompilation runs in subprocess, so its error carries no frame inside package; this load shows them.
With uuid, `using` inside resolves dependencies of `id`. `nothing` for extension: Base matches extension by
root module name, which anonymous module lacks, so `using` resolves from environment top level.
Result is `nothing` when load succeeds here.
"""
function reproduce(entry::String, id::Union{Nothing, Base.PkgId})::Union{Nothing, Tuple{Any, Vector{Base.StackTraces.StackFrame}}}
    container = Module()
    # Module form inherits container uuid, as package module inherits uuid Base sets on `__toplevel__`.
    isnothing(id) || ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), container, convert(NTuple{2, UInt64}, id.uuid))
    try
        Base.include(container, entry)
        return nothing
    catch error
        error isa InterruptException && rethrow()
        return error, stacktrace(catch_backtrace())
    end
end

"""
`load-error` finding for `error` with `frames`, saying `subject` does not load and `missed` what rules missed.
Primary span: line of innermost frame in analyzed file; first line of `entry` when none, or when entry is not analyzed.
"""
function load_error(error::Any, frames::Vector{Base.StackTraces.StackFrame}, entry::String, files::Vector{SyntaxFile}, subject::String, missed::String)::Finding
    by_path = Dict(file.path => file for file in files)
    index = findfirst(frame -> haskey(by_path, string(frame.file)), frames)
    file, line = isnothing(index) ? (get(by_path, entry, nothing), 1) : (by_path[string(frames[index].file)], frames[index].line)
    starts = isnothing(file) ? [1] : line_starts(file.text)
    path, start = isnothing(file) ? (entry, 1) : (file.path, starts[clamp(line, 1, length(starts))])
    message = first(split(sprint(showerror, unwrapped(error)), '\n'))
    return Finding(
        LOAD_ERROR, :load_error, Confidence.definite, "$subject does not load", Label(Span(path, start, start, Precision.line), message),
        Label[], "Julia cannot load $subject; $missed", Facts.manual_fix("fix error at marked line"),
    )
end

"""Outcome of package load: facts when root module loads, `load-error` findings, and parts rules could not see."""
struct Loaded
    facts::Union{Nothing, PackageFacts}
    errors::Vector{Finding}
    blind_spots::Vector{BlindSpot}
end

"""
Whether every package of `triggers` loads. Julia logs error of extension they activate; failure here is trigger's own.
"""
function loads_triggers(triggers::Vector{Base.PkgId})::Bool
    try
        foreach(Base.require, triggers)
        return true
    catch error
        error isa InterruptException && rethrow()
        return false
    end
end

"""
Load triggers of each extension of `mod` in `project`; extension activates once all its triggers load.
Extension with trigger environment cannot find or load becomes blind spot; extension that throws, `load-error` finding.
"""
function load_extensions(mod::Module, project::ProjectFacts, files::Vector{SyntaxFile})::Tuple{Vector{Finding}, Vector{BlindSpot}}
    errors, blind_spots = Finding[], BlindSpot[]
    for (; name, file, triggers) in project.extensions
        if any(trigger -> isnothing(Base.locate_package(trigger)), triggers)
            push!(blind_spots, BlindSpot("extension trigger not installed", Span(file, 1, 1, Precision.line)))
            continue
        end
        if !loads_triggers(triggers)
            push!(blind_spots, BlindSpot("extension trigger did not load", Span(file, 1, 1, Precision.line)))
            continue
        end
        isnothing(Base.get_extension(mod, Symbol(name))) || continue
        # Precompile-only failure: Julia logged error, and load in anonymous module succeeds.
        error, frames = something(reproduce(file, nothing), (ErrorException("extension `$name` failed to precompile; Julia logged error"), Base.StackTraces.StackFrame[]))
        finding = load_error(error, frames, file, files, "extension `$name`", "rules did not see extension")
        push!(errors, finding)
        push!(blind_spots, BlindSpot("extension did not load", finding.primary.span))
    end
    return errors, blind_spots
end

"""
Blind spots for packages this process loaded at other version than target Manifest of `project` pins; each at its entry.
Relaunch moves version only when Corset needs other one; rules then read code target does not run.
"""
function moved_versions(project::ProjectFacts)::Vector{BlindSpot}
    manifest = Base.project_file_manifest_path(joinpath(project.root, "Project.toml"))
    isnothing(manifest) && return BlindSpot[]
    text, spots = read(manifest, String), BlindSpot[]
    for (name, entries) in get(parse_toml(manifest), "deps", Dict{String, Any}())
        headers = findall("[[deps.$name]]", text)
        for (index, entry) in enumerate(entries)
            haskey(entry, "version") || continue
            loaded = get(Base.loaded_modules, Base.PkgId(Base.UUID(entry["uuid"]), name), nothing)
            (isnothing(loaded) || pkgversion(loaded) == VersionNumber(entry["version"])) && continue
            # Hand-written header Pkg would not write (`[[deps."Name"]]`): point at line 1.
            header = get(headers, index, 1:1)
            push!(spots, BlindSpot("loaded version differs from Manifest", Span(manifest, first(header), last(header), Precision.line)))
        end
    end
    return sort!(spots; by = spot -> spot.span.first_byte)
end

"""
Facts of package of `project`, loaded in this process with extension triggers, with method sites in `files`.
Precompile failure carries no frame inside package, so error comes from second load in anonymous module (`reproduce`).
"""
function load(project::ProjectFacts, files::Vector{SyntaxFile})::Loaded
    entry = project.entry
    mod = try
        load_module(package_id(project), entry)
    catch error
        error isa ConfigError && rethrow()
        frames = stacktrace(catch_backtrace())
        if error isa Base.Precompilation.PkgPrecompileError
            again = reproduce(entry, package_id(project))
            isnothing(again) || ((error, frames) = again)
        end
        finding = load_error(error, frames, entry, files, "package", "rules after `syntax` stage did not run")
        return Loaded(nothing, [finding], [BlindSpot("package did not load", finding.primary.span); moved_versions(project)])
    end
    errors, blind_spots = load_extensions(mod, project, files)
    return Loaded(package_facts(package_modules(mod, project), files), errors, [blind_spots; moved_versions(project)])
end

"""Facts of loaded package `modules`, root module first, with method and struct sites in `files`."""
function package_facts(modules::Vector{Module}, files::Vector{SyntaxFile})::PackageFacts
    sites = method_sites(modules, files)
    return PackageFacts(modules, public_values(modules), sites, overwrites(sites), struct_sites(sites, files))
end

end
