"""
`package` stage: load target package into this process; collect package modules, public values, method sites and struct sites.

Environment must load package from its root (`Base.locate_package`); other environment is config error.
Load that throws becomes `load-error` finding, as `parse-error`.
Each extension whose triggers environment can load gets them loaded; extension that throws gets `load-error` finding.
"""
module Package

using ..Facts: Facts, line_starts, lowered_value, PackageFacts, ProjectFacts, MethodSite, StructSite, SyntaxFile, SyntaxNode, Finding, Label, Span, Precision, Confidence, BlindSpot
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
function public_values(modules::AbstractVector{Module})::Base.IdSet{Any}
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

"""
Whether definition `node` declares at least as many arguments as `method` takes. Macro can add arguments at definition
line: DynamicPPL `@model f(x)` also defines `f(__model__, __varinfo__, x)`.
"""
function fits(node::SyntaxNode, method::Method)::Bool
    parts = Facts.signature(node)
    isnothing(parts) && return true
    declared = 0
    for part in parts.arguments
        # Keyword body `#f#3` takes keywords and function itself before positional arguments.
        keywords = Facts.kind_name(part) == "parameters"
        declared += keywords ? (source_name(method) == string(method.name) ? 0 : length(Facts.children_of(part)) + 1) : 1
    end
    return declared >= length(Facts.tuple_parameters(method.sig)) - 1
end

"""
Site of `method` in `file`: exact when one definition of its source name and fitting arity (`fits`) starts on method
line, line precision otherwise.
"""
function method_site(method::Method, file::SyntaxFile, lines::Lines)::MethodSite
    candidates = filter(node -> defined_name(file, node) == source_name(method) && fits(node, method), get(lines.definitions, method.line, SyntaxNode[]))
    length(candidates) == 1 && return MethodSite(method, file, only(candidates), Facts.span(file, only(candidates)))
    start = lines.starts[method.line]
    return MethodSite(method, file, nothing, Span(file.path, start, start, Precision.line))
end

"""Sites of methods `modules` define in `files`, sorted by file and position; generated methods left out."""
function method_sites(modules::AbstractVector{Module}, files::AbstractVector{SyntaxFile})::Vector{MethodSite}
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

"""Struct types named `name` that package `modules` define."""
function named_structs(modules::AbstractVector{Module}, name::Symbol)::Vector{Type}
    found = Type[]
    for mod in modules
        isdefined(mod, name) || continue
        body = Base.unwrap_unionall(getglobal(mod, name))
        body isa DataType && isstructtype(body) && parentmodule(body) === mod && body.name.name === name && push!(found, body.name.wrapper)
    end
    return found
end

"""
Sites of structs that constructor method `sites` tie to `struct` forms in `files`.
Default constructors start on first field line, or on struct line for struct without fields; inner constructors start
in body. So constructor of same name that starts between line start of form and its end builds its type.
Macro that builds struct (`@concrete struct`) gives constructors its own file; then sole struct of that name in
package `modules` ties.
"""
function struct_sites(sites::AbstractVector{MethodSite}, files::AbstractVector{SyntaxFile}, modules::AbstractVector{Module})::Vector{StructSite}
    built = Dict{String, Vector{Tuple{Int, Core.TypeName}}}()
    for site in sites
        name = constructed(site.method)
        isnothing(name) || push!(get!(built, site.span.file, Tuple{Int, Core.TypeName}[]), (site.span.first_byte, name))
    end
    # Untied form keeps its slot, so sites stay in file order: stand-in order decides which signatures fit `LIMIT`.
    found, untied = Union{Nothing, StructSite}[], Tuple{Int, SyntaxFile, SyntaxNode, Symbol}[]
    for file in files
        starts, constructors = line_starts(file.text), get(built, file.path, Tuple{Int, Core.TypeName}[])
        for node in Facts.forms(file, "struct")
            bytes = Facts.trimmed_bytes(file.text, node)
            lines, name = starts[searchsortedlast(starts, first(bytes))]:last(bytes), Symbol(Facts.source(file, Facts.definition_name(node)))
            index = findfirst(((byte, type),) -> byte in lines && type.name === name, constructors)
            push!(found, isnothing(index) ? nothing : StructSite(last(constructors[index]).wrapper, file, node))
            isnothing(index) && push!(untied, (length(found), file, node, name))
        end
    end
    tied = Set{Type}(site.type for site in found if !isnothing(site))
    for (slot, file, node, name) in untied
        named = filter(type -> !(type in tied), named_structs(modules, name))
        length(named) == 1 && (found[slot] = StructSite(only(named), file, node))
    end
    return StructSite[site for site in found if !isnothing(site)]
end

"""
Pairs (earlier, later) of `sites` where later definition replaced earlier one with same signature.
Julia keeps replaced method in method table with `dispatch_status` 0 and numbers definitions by `primary_world`.
"""
function overwrites(sites::AbstractVector{MethodSite})::Vector{Tuple{MethodSite, MethodSite}}
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
function load_error(error::Any, frames::AbstractVector{Base.StackTraces.StackFrame}, entry::String, files::AbstractVector{SyntaxFile}, subject::String, missed::String)::Finding
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
function loads_triggers(triggers::AbstractVector{Base.PkgId})::Bool
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
function load_extensions(mod::Module, project::ProjectFacts, files::AbstractVector{SyntaxFile})::Tuple{Vector{Finding}, Vector{BlindSpot}}
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
function load(project::ProjectFacts, files::AbstractVector{SyntaxFile})::Loaded
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

"""Functions that answer whether function takes arguments."""
const REFLECTION = Union{typeof(applicable), typeof(hasmethod), typeof(which), typeof(methods)}

"""Leading operands of splat parts `parts` of `Core._apply_iterate` call: elements of each `tuple(...)` part until other part."""
function splatted(code::AbstractVector{Any}, parts::AbstractVector{Any})::Vector{Any}
    operands = Any[]
    for part in parts
        part isa Core.SSAValue || break
        tuple = code[part.id]
        tuple isa Expr || break
        (tuple.head === :call && lowered_value(code, tuple.args[1]) === Core.tuple) || break
        append!(operands, tuple.args[2:end])
    end
    return operands
end

"""
Calls of lowered `code`: statement index, callee value, callee operand and positional operands.
Splat call `f(a, xs...)` keeps `a`.
"""
function lowered_calls(code::AbstractVector{Any})::Vector{Tuple{Int, Any, Any, Vector{Any}}}
    found = Tuple{Int, Any, Any, Vector{Any}}[]
    for (index, statement) in pairs(code)
        call = statement isa Expr && statement.head === :(=) ? statement.args[2] : statement
        call isa Expr || continue
        call.head === :call || continue
        head, operands = call.args[1], call.args[2:end]
        if lowered_value(code, head) === Core._apply_iterate && length(operands) >= 2
            head, operands = operands[2], splatted(code, operands[3:end])
        end
        push!(found, (index, lowered_value(code, head), head, operands))
    end
    return found
end

"""Type of function, type or callable object `method` belongs to: `Core.Typeof` of callee value that can run it."""
callee_type(method::Method)::Type = Base.rewrap_unionall(Facts.tuple_parameters(method.sig)[1], method.sig)

"""
Branch `MethodError` takes at condition `condition` of lowered `code` when it tests caught exception in slot `caught`:
`true` when condition holds, `false` when it fails, `nothing` for other condition.
"""
function method_error_branch(code::AbstractVector{Any}, condition::Any, caught::Any)::Union{Nothing, Bool}
    condition isa Core.SSAValue || return nothing
    test = code[condition.id]
    test isa Expr || return nothing
    (test.head === :call && length(test.args) == 3) || return nothing
    subject = test.args[2]
    subject isa Core.SSAValue && (subject = code[subject.id])
    (subject == caught && lowered_value(code, test.args[1]) === isa) || return nothing
    type = lowered_value(code, test.args[3])
    type isa Type || return nothing
    MethodError <: type && return true
    return typeintersect(MethodError, type) === Union{} ? false : nothing
end

"""Whether lowered `statement` of `code` calls `rethrow` or `throw`."""
function throws(code::AbstractVector{Any}, statement::Any)::Bool
    call = statement isa Expr && statement.head === :(=) ? statement.args[2] : statement
    call isa Expr || return false
    return call.head === :call && lowered_value(code, call.args[1]) isa Union{typeof(rethrow), typeof(throw)}
end

"""
Whether handler at `catch_dest` of `try` that statement `enter` of lowered `code` opens can finish on `MethodError`:
some path reaches its `pop_exception` or return without `rethrow`. `try`/`finally` handler always rethrows.
"""
function swallows(code::AbstractVector{Any}, enter::Integer, catch_dest::Integer)::Bool
    head = code[catch_dest]
    caught = head isa Expr && head.head === :(=) && head.args[2] == Expr(:the_exception) ? head.args[1] : nothing
    pending, seen = [catch_dest], Set{Int}()
    while !isempty(pending)
        index = pop!(pending)
        (index in seen || index > lastindex(code)) && continue
        push!(seen, index)
        statement = code[index]
        statement isa Expr && statement.head === :pop_exception && statement.args[1] == Core.SSAValue(enter) && return true
        if statement isa Core.ReturnNode
            # Return node without value marks unreachable code.
            isdefined(statement, :val) && return true
        elseif statement isa Core.GotoNode
            push!(pending, statement.label)
        elseif statement isa Core.GotoIfNot
            # Type test of caught exception sends `MethodError` one way; other condition, both ways.
            branch = method_error_branch(code, statement.cond, caught)
            branch === false || push!(pending, index + 1)
            branch === true || push!(pending, statement.dest)
        elseif !throws(code, statement)
            push!(pending, index + 1)
        end
    end
    return false
end

"""Statements of lowered `code` inside `try` whose handler swallows `MethodError`."""
function guarded_statements(code::AbstractVector{Any})::Set{Int}
    guarded = Set{Int}()
    for (enter, statement) in pairs(code)
        statement isa Core.EnterNode || continue
        # IR marks scope without handler as `EnterNode(0)`.
        statement.catch_dest > 0 || continue
        swallows(code, enter, statement.catch_dest) && union!(guarded, (enter + 1):(statement.catch_dest - 1))
    end
    return guarded
end

"""
Record that lowered `code` of `method` tests `operand` for methods: argument adds its position under callee type
`key` to `exact` (concrete `key`) or `inexact`, other operand adds its value to `found`. Return whether positions grew.
"""
function tested!(found::Base.IdSet{Any}, exact::IdDict{<:Type, <:AbstractSet{<:Integer}}, inexact::IdDict{<:Type, <:AbstractSet{<:Integer}}, key::Type, method::Method, code::AbstractVector{Any}, operand::Any)::Bool
    operand isa Core.SSAValue && (operand = code[operand.id])
    # Local `target = f` stands for argument `f`.
    operand isa Core.SlotNumber && operand.id > method.nargs && (operand = Facts.assigned_once(code, operand))
    operand isa Core.SSAValue && (operand = code[operand.id])
    if operand isa Core.SlotNumber && 2 <= operand.id <= method.nargs
        tested = get!(Set{Int}, isconcretetype(key) ? exact : inexact, key)
        (operand.id - 1) in tested && return false
        push!(tested, operand.id - 1)
        return true
    end
    push!(found, lowered_value(code, operand))
    return false
end

"""
Argument positions call of `callee` tests for methods: reflection tests first; package methods their positions in
`exact` under `Core.Typeof(callee)`, or in `inexact` under supertype of it. Position can repeat.
"""
function tested_positions(callee::Any, exact::IdDict{<:Type, <:AbstractSet{<:Integer}}, inexact::IdDict{<:Type, <:AbstractSet{<:Integer}})::Vector{Int}
    callee isa REFLECTION && return [1]
    positions = Int[]
    isnothing(callee) && return positions
    type = Core.Typeof(callee)
    haskey(exact, type) && append!(positions, exact[type])
    # Parametric callable types and constructors (`Type{T}`) match by subtype; package has few of them.
    for (key, tested) in inexact
        type <: key && append!(positions, tested)
    end
    return positions
end

"""
Functions, types and callable objects lowered code of `methods` tests for methods: passes to reflection call
(`REFLECTION`) or calls in `try` whose handler swallows `MethodError`, directly or through argument of package method.
Generated methods pass: they keep generator only.
"""
function probed(methods::AbstractVector{Method})::Base.IdSet{Any}
    # Typed: element with `Type` field infers abstract, and `Any` callers below would invalidate.
    bodies = Tuple{Method, Vector{Any}, Type}[(method, Base.uncompressed_ast(method).code, callee_type(method)) for method in methods if isdefined(method, :source)]
    calls = [(lowered_calls(code), guarded_statements(code)) for (_, code, _) in bodies]
    found = Base.IdSet{Any}()
    # Tested argument positions by callee type; each pass costs one lookup per call, and passes end when none grows.
    exact, inexact, grown = IdDict{Type, Set{Int}}(), IdDict{Type, Set{Int}}(), true
    while grown
        grown = false
        for ((method, code, key), (method_calls, guarded)) in zip(bodies, calls), (index, callee, head, operands) in method_calls
            index in guarded && (grown |= tested!(found, exact, inexact, key, method, code, head))
            for position in tested_positions(callee, exact, inexact)
                position <= length(operands) || continue
                grown |= tested!(found, exact, inexact, key, method, code, operands[position])
            end
        end
    end
    delete!(found, nothing)
    return found
end

"""Facts of loaded package `modules`, root module first, with method and struct sites in `files`."""
function package_facts(modules::AbstractVector{Module}, files::AbstractVector{SyntaxFile})::PackageFacts
    sites = method_sites(modules, files)
    return PackageFacts(modules, public_values(modules), sites, overwrites(sites), struct_sites(sites, files, modules), probed([site.method for site in sites]))
end

end
