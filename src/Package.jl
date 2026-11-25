"""
`package` stage: load target package into this process; collect package modules, public values, method sites and struct sites.

Environment must load package from its root (`Base.locate_package`); other environment is config error.
Load that throws becomes `load-error` finding, as `parse-error`.
Each extension whose triggers environment can load gets them loaded; extension that throws gets `load-error` finding.
"""
module Package

using ..Facts: Facts, line_starts, lowered_value, ArgumentUse, RESIZE_FUNCTIONS, PackageFacts, ProjectFacts, MethodSite, StructSite, SyntaxFile, SyntaxNode, Finding, Label, Span, Precision, Confidence, BlindSpot
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

"""Methods of package `modules`, generated methods (closures, keyword bodies) included."""
function module_methods(modules::AbstractVector{Module})::Vector{Method}
    package = Set(modules)
    methods = Method[]
    Base.visit(Core.methodtable) do method
        method.module in package && push!(methods, method)
    end
    return methods
end

"""Sites of `methods` (`module_methods`) in `files`, sorted by file and position; generated methods left out."""
function method_sites(methods::AbstractVector{Method}, files::AbstractVector{SyntaxFile})::Vector{MethodSite}
    by_path = Dict(file.path => file for file in files)
    lines = Dict(file.path => Lines(file) for file in files)
    sites = MethodSite[]
    for method in methods
        generated(method) && continue
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

"""Lowered code of each of `methods` with type of its callee (`callee_type`); generated methods pass, since they keep generator only."""
function lowered_bodies(methods::AbstractVector{Method})::Vector{Tuple{Method, Vector{Any}, Type}}
    # Typed: element with `Type` field infers abstract, and `Any` callers below would invalidate.
    return Tuple{Method, Vector{Any}, Type}[(method, Base.uncompressed_ast(method).code, callee_type(method)) for method in methods if isdefined(method, :source)]
end

"""
Functions, types and callable objects lowered `bodies` (`lowered_bodies`) test for methods: passes to reflection call
(`REFLECTION`) or calls in `try` whose handler swallows `MethodError`, directly or through argument of package method.
"""
function probed(bodies::AbstractVector{<:Tuple{Method, AbstractVector{Any}, Type}})::Base.IdSet{Any}
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

"""Argument a value of lowered code comes from: position, or field name of closure object; and whether value is its element."""
const Origin = Tuple{Union{Int, Symbol}, Bool}

"""Argument uses of one method during `argument_uses`, by position and by captured field name."""
const Uses = Dict{Union{Int, Symbol}, ArgumentUse}

"""Use without need: start of join (`record!`)."""
const NO_USE = ArgumentUse(false, false, Any[])

"""Use of argument that body resizes (`RESIZE_FUNCTIONS`)."""
const RESIZED = ArgumentUse(true, false, Any[])

"""Use of argument whose callee or callee position is unknown: open callee, splat, vararg, keyword value. Every resize counts."""
const UNKNOWN = ArgumentUse(true, true, Any[])

"""
Locals of one lowered body, by slot: values each gets (`assigned`), origins (`Origin`) each holds, joined over every
value it gets, and value of each constant local (`constants`, see `constant_value`), `#self#` included. `body_locals`
builds index once per body, so slot read scans no statement.
"""
struct Locals
    assigned::Dict{Int, Vector{Any}}
    origins::Dict{Int, Vector{Origin}}
    constants::Dict{Int, Some}
end

"""
Origins (`Origin`) value `operand` of lowered `code` can hold, for method with `nargs` arguments: argument, field of
closure object (`getfield(#self#, :name)`), or element `getindex` or `for` loop reads from either. Join ignores order:
local (slot past arguments) holds origins of every value it gets (`Locals`).
"""
function origins(code::AbstractVector{Any}, nargs::Integer, locals::Locals, @nospecialize(operand::Any))::Vector{Origin}
    operand isa Core.SSAValue && (operand = code[operand.id])
    # Lowering copies argument into local before body assigns it; slot 1 is callee.
    operand isa Core.SlotNumber && return operand.id > nargs ? get(locals.origins, operand.id, Origin[]) : operand.id >= 2 ? [(operand.id - 1, false)] : Origin[]
    operand isa Expr || return Origin[]
    (operand.head === :call && length(operand.args) >= 2) || return Origin[]
    callee, subject = lowered_value(code, operand.args[1]), operand.args[2]
    if callee === getfield && length(operand.args) == 3
        field = operand.args[3]
        subject == Core.SlotNumber(1) && field isa QuoteNode && field.value isa Symbol && return [(field.value, false)]
        # `for x in X` reads `x` as field 1 of `iterate(X, ...)` result.
        field === 1 || return Origin[]
        inner = iterated(code, nargs, locals, subject)
    elseif callee === getindex
        inner = origins(code, nargs, locals, subject)
    else
        return Origin[]
    end
    return Origin[(key, true) for (key, element) in inner if !element]
end

"""Origins (`origins`) of collections local `state` iterates: values of its assignments `state = iterate(X, ...)`."""
function iterated(code::AbstractVector{Any}, nargs::Integer, locals::Locals, @nospecialize(state::Any))::Vector{Origin}
    state isa Core.SSAValue && (state = code[state.id])
    found = Origin[]
    state isa Core.SlotNumber || return found
    for call in get(locals.assigned, state.id, Any[])
        call isa Expr || continue
        (call.head === :call && length(call.args) >= 2 && lowered_value(code, call.args[1]) === iterate) || continue
        union!(found, origins(code, nargs, locals, call.args[2]))
    end
    return found
end

"""
`Locals` of lowered `code` of `method`: origins join over assignments until none grows. `#self#` (slot 1) is constant
when function type of `method` is singleton: default-argument method calls own function through it.
"""
function body_locals(code::AbstractVector{Any}, method::Method)::Locals
    locals = Locals(Dict{Int, Vector{Any}}(), Dict{Int, Vector{Origin}}(), Dict{Int, Some}())
    self = first(Facts.tuple_parameters(method.sig))
    Base.issingletontype(self) && (locals.constants[1] = Some(self.instance))
    nargs = Int(method.nargs)
    for statement in code
        statement isa Expr || continue
        target = statement.head === :(=) ? statement.args[1] : nothing
        target isa Core.SlotNumber && push!(get!(Vector{Any}, locals.assigned, target.id), statement.args[2])
    end
    # Statement order: local read before its one assignment (cycle `T = Vector{T}` too) counts as not constant.
    for statement in code
        statement isa Expr || continue
        target = statement.head === :(=) ? statement.args[1] : nothing
        target isa Core.SlotNumber || continue
        length(locals.assigned[target.id]) == 1 || continue
        found = constant_value(code, locals, statement.args[2])
        isnothing(found) || (locals.constants[target.id] = found)
    end
    grown = true
    while grown
        grown = false
        for (slot, values) in locals.assigned, assigned in values
            known = get!(Vector{Origin}, locals.origins, slot)
            fresh = setdiff(origins(code, nargs, locals, assigned), known)
            isempty(fresh) || (append!(known, fresh); grown = true)
        end
    end
    return locals
end

"""
Statement or value `operand` of lowered `code` stands for, through statements and chains of locals assigned once.
`nothing` for argument, local assigned more than once, and cycle of locals (`c = c`).
"""
function resolved(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any))::Any
    # Chain without cycle visits each local once.
    for _ in 0:length(locals.assigned)
        operand isa Core.SSAValue && (operand = code[operand.id])
        operand isa Core.SlotNumber || return operand
        assigned = get(locals.assigned, operand.id, nothing)
        isnothing(assigned) && return nothing
        length(assigned) == 1 || return nothing
        operand = only(assigned)
    end
    return nothing
end

"""`lowered_value` of `operand` of lowered `code`, with locals read from `locals` index."""
local_value(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any))::Any = lowered_value(code, resolved(code, locals, operand))

"""Whether `operand` of lowered `code` is function or type: global, type application or closure object (`new`)."""
function callable(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any))::Bool
    local_value(code, locals, operand) isa Base.Callable && return true
    operand isa Core.SSAValue || return false
    statement = code[operand.id]
    statement isa Expr || return false
    return statement.head === :new || (statement.head === :call && lowered_value(code, statement.args[1]) === Core.apply_type)
end

"""Resizing functions with method that takes function first and collection second: `filter!(f, a)`, `get!(f, d, k)`."""
const FUNCTION_FIRST = Base.IdSet{Any}(Any[filter!, unique!, merge!, mergewith!, get!])

"""
Positions of `operands` of resizing call to `callee` in lowered `code` of `method` that can hold collection call resizes.
`FUNCTION_FIRST` call with two operands or more gives both when first operand (`held` origins) is of unknown kind.
"""
function resized_positions(code::AbstractVector{Any}, locals::Locals, method::Method, @nospecialize(callee::Any), operands::AbstractVector, held::AbstractVector{<:AbstractVector{Origin}})::UnitRange{Int}
    isempty(operands) && return 1:0
    (callee in FUNCTION_FIRST && length(operands) >= 2) || return 1:1
    callable(code, locals, first(operands)) && return 2:2
    declared = length(first(held)) == 1 ? declared_type(method, only(first(held))) : nothing
    isnothing(declared) && return 1:2
    declared <: Base.Callable && return 2:2
    return declared <: Union{AbstractArray, AbstractDict, AbstractSet} ? (1:1) : (1:2)
end

"""
Declared type of argument `origin` of `method`: tuple for vararg argument; for element, dictionary value or `eltype`.
`nothing` for closure field.
"""
function declared_type(method::Method, origin::Origin)::Union{Nothing, Type}
    (position, element) = origin
    parameters = Facts.tuple_parameters(method.sig)
    position isa Int || return nothing
    length(parameters) > position || return nothing
    parameter = parameters[position + 1]
    declared = Base.rewrap_unionall(Base.isvarargtype(parameter) ? Tuple{parameter} : parameter, method.sig)
    return element ? element_type(declared) : declared
end

"""
Type `getindex` reads from collection of `declared` type: value of `AbstractDict` supertype, element of `AbstractArray`
supertype, else `Any`. Supertypes give it: `eltype` and `valtype` could run package code.
"""
function element_type(declared::Type)::Type
    body = Base.unwrap_unionall(declared)
    while body isa DataType && body !== Any
        index = body.name === Base.typename(AbstractDict) ? 2 : body.name === Base.typename(AbstractArray) ? 1 : 0
        index == 0 || return body.parameters[index] isa Type ? body.parameters[index] : Any
        body = supertype(body)
    end
    return Any
end

"""
Known type of `operand` of lowered `code` of `method`: declared type of its one origin (`held`), literal, value of
constant global, or declared type of other global; else `Any`.
"""
function operand_type(code::AbstractVector{Any}, method::Method, @nospecialize(operand::Any), held::AbstractVector{<:Origin})::Type
    # Element origin can be slice (`x[1:2]`): its type is unknown.
    declared = length(held) == 1 && !last(only(held)) ? declared_type(method, only(held)) : nothing
    isnothing(declared) || return declared
    operand isa Core.SSAValue && (operand = code[operand.id])
    operand isa QuoteNode && return Core.Typeof(operand.value)
    operand isa Union{Core.SlotNumber, Expr} && return Any
    operand isa GlobalRef || return Core.Typeof(operand)
    isdefined(operand.mod, operand.name) || return Any
    # Body can rebind non-constant global to value of other type.
    return isconst(operand.mod, operand.name) ? Core.Typeof(getglobal(operand.mod, operand.name)) : Core.get_binding_type(operand.mod, operand.name)
end

"""Call of statement `index` of lowered `code`: right side of assignment, or statement itself."""
function statement_call(code::AbstractVector{Any}, index::Integer)::Any
    statement = code[index]
    return statement isa Expr && statement.head === :(=) ? statement.args[2] : statement
end

"""Whether statement `index` of lowered `code` is splat call (`Core._apply_iterate`): `lowered_calls` keeps leading operands only."""
function splat_call(code::AbstractVector{Any}, index::Integer)::Bool
    call = statement_call(code, index)
    return call isa Expr && lowered_value(code, call.args[1]) === Core._apply_iterate
end

"""Operands of splat call at statement `index` of lowered `code`: elements of `tuple(...)` parts, and other parts."""
function splat_operands(code::AbstractVector{Any}, index::Integer)::Vector{Any}
    call = statement_call(code, index)
    found = Any[]
    call isa Expr || return found
    # Operands: `_apply_iterate`, `iterate`, callee, parts.
    for part in call.args[4:end]
        tuple = part isa Core.SSAValue ? code[part.id] : nothing
        if tuple isa Expr && tuple.head === :call && lowered_value(code, tuple.args[1]) === Core.tuple
            append!(found, tuple.args[2:end])
        else
            push!(found, part)
        end
    end
    return found
end

"""Values of keyword arguments `names` operand of `Core.kwcall` in lowered `code` holds: `NamedTuple{names}(tuple(values...))`."""
function keyword_values(code::AbstractVector{Any}, @nospecialize(names::Any))::Vector{Any}
    built = names isa Core.SSAValue ? code[names.id] : nothing
    built isa Expr || return Any[]
    (built.head === :call && length(built.args) == 2) || return Any[]
    values = built.args[2] isa Core.SSAValue ? code[built.args[2].id] : nothing
    return values isa Expr && values.head === :call && lowered_value(code, values.args[1]) === Core.tuple ? values.args[2:end] : Any[]
end

"""Whether argument `position` of call to `method` lands in its vararg parameter."""
vararg_position(method::Method, position::Integer)::Bool = (parameters = Facts.tuple_parameters(method.sig); Base.isvarargtype(last(parameters)) && position >= length(parameters) - 1)

"""
Value of `operand` of lowered `code` on every run, when constant: constant global, `Module.name` of constant in constant
module, literal, local assigned once, or type application of constant values. `nothing` for other operand: argument,
closure, call result, static parameter, non-constant global. Local reads `locals.constants`.
"""
function constant_value(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any))::Union{Nothing, Some}
    operand isa Core.SSAValue && return constant_value(code, locals, code[operand.id])
    operand isa Core.SlotNumber && return get(locals.constants, operand.id, nothing)
    operand isa QuoteNode && return Some(operand.value)
    operand isa GlobalRef && return isdefined(operand.mod, operand.name) && isconst(operand.mod, operand.name) ? Some(getglobal(operand.mod, operand.name)) : nothing
    operand isa Expr || return Some(operand)
    operand.head === :call || return nothing
    known = Union{Nothing, Some}[constant_value(code, locals, part) for part in operand.args]
    any(isnothing, known) && return nothing
    (callee, parts...) = Any[something(part) for part in known]
    callee === Core.apply_type && return try
        Some(Core.apply_type(parts...))
    catch error
        # Builtin `apply_type` rejects bad parameter count or kind; it runs no package code.
        error isa Union{TypeError, ErrorException} ? nothing : rethrow()
    end
    # Lowering turns `Base.f` into `getproperty(Base, :f)`.
    (callee === getproperty && length(parts) == 2 && parts[1] isa Module && parts[2] isa Symbol) || return nothing
    (owner, name) = parts
    return isdefined(owner, name) && isconst(owner, name) ? Some(getglobal(owner, name)) : nothing
end

"""Package methods function operand `operand` of lowered `code` can run: closure object it builds, or `targets` of its value."""
function function_methods(code::AbstractVector{Any}, locals::Locals, @nospecialize(operand::Any), targets::Function, closures::AbstractDict{Core.TypeName, <:AbstractVector{Method}})::Vector{Method}
    built = resolved(code, locals, operand)
    built isa Expr || return targets(local_value(code, locals, operand))
    built.head === :new || return targets(local_value(code, locals, operand))
    wrapper = Base.unwrap_unionall(built_type(code, built.args[1]))
    return wrapper isa DataType ? Vector{Method}(get(closures, wrapper.name, Method[])) : Method[]
end

"""Type `new` operand `operand` of lowered `code` builds: global, or `apply_type` of global, as closure over typed captures."""
function built_type(code::AbstractVector{Any}, @nospecialize(operand::Any))::Any
    operand isa Core.SSAValue && (operand = code[operand.id])
    operand isa Expr && operand.head === :call && lowered_value(code, operand.args[1]) === Core.apply_type && (operand = operand.args[2])
    return lowered_value(code, operand)
end

"""
Join `use` into entry `key` of `uses`: use of element (`element`) adds its resizes to elements, other use adds all.
Element origin can be slice, whose elements are elements of argument. Return whether entry changed.
"""
function record!(uses::Uses, key::Union{Integer, Symbol}, use::ArgumentUse, element::Bool)::Bool
    old = get(uses, key, NO_USE)
    new = element ? ArgumentUse(old.resized, old.elements_resized || use.resized || use.elements_resized, old.stored) :
        ArgumentUse(old.resized || use.resized, old.elements_resized || use.elements_resized, union(old.stored, use.stored))
    (new.resized, new.elements_resized, length(new.stored)) == (old.resized, old.elements_resized, length(old.stored)) && return false
    uses[key] = new
    return true
end

"""
Uses that struct `type` gives values `new` or default constructor stores into its fields, by field: declared field
type, or `nothing` for field typed by parameter. Closure and other module's type give `nothing`.
"""
function field_uses(@nospecialize(type::Any), modules::AbstractSet{Module})::Union{Nothing, Vector{Union{Nothing, ArgumentUse}}}
    wrapper = Base.unwrap_unionall(type)
    wrapper isa DataType || return nothing
    (wrapper.name.module in modules && isstructtype(wrapper) && !(wrapper <: Function)) || return nothing
    return Union{Nothing, ArgumentUse}[Base.has_free_typevars(field) ? nothing : ArgumentUse(false, false, Any[field]) for field in fieldtypes(wrapper)]
end

"""Push to `fixed` use (`field_uses`) of each `held` operand origin constructor of `type` stores, when it takes one per field."""
function push_field_uses!(fixed::AbstractVector{Tuple{Origin, ArgumentUse}}, @nospecialize(type::Any), held::AbstractVector{<:AbstractVector{Origin}}, modules::AbstractSet{Module})::Nothing
    fields = field_uses(type, modules)
    (isnothing(fields) || length(fields) != length(held)) && return nothing
    for (use, reached) in zip(fields, held), origin in reached
        isnothing(use) || last(origin) || push!(fixed, (origin, use))
    end
    return nothing
end

"""
Steps of `method` with lowered `code` for `argument_uses`: fixed uses of operand origins, and links from origin to entry
`key` of other methods. `targets` gives package methods callee value can run.
"""
function use_steps(code::AbstractVector{Any}, method::Method, targets::Function, closures::AbstractDict{Core.TypeName, <:AbstractVector{Method}}, modules::AbstractSet{Module})::Tuple{Vector{Tuple{Origin, ArgumentUse}}, Vector{Tuple{Origin, Vector{Method}, Int}}}
    fixed, links = Tuple{Origin, ArgumentUse}[], Tuple{Origin, Vector{Method}, Int}[]
    nargs, locals = Int(method.nargs), body_locals(code, method)
    for (index, callee, head, operands) in lowered_calls(code)
        held = Vector{Origin}[origins(code, nargs, locals, operand) for operand in operands]
        if callee in RESIZE_FUNCTIONS || callee === get!
            for position in resized_positions(code, locals, method, callee, operands, held), origin in held[position]
                push!(fixed, (origin, RESIZED))
            end
        elseif callee === setindex! && !isempty(held)
            # Array element write keeps size; dictionary write can add key.
            for origin in first(held)
                declared = declared_type(method, origin)
                !isnothing(declared) && typeintersect(declared, AbstractDict) !== Union{} && push!(fixed, (origin, RESIZED))
            end
        end
        types = Type[operand_type(code, method, operand, origins) for (operand, origins) in zip(operands, held)]
        keywords = callee === Core.kwcall && length(operands) >= 2 ? keyword_values(code, first(operands)) : Any[]
        callee === Core.kwcall && length(operands) >= 2 && ((callee, head, operands, held, types) = (lowered_value(code, operands[2]), operands[2], operands[3:end], held[3:end], types[3:end]))
        push_field_uses!(fixed, callee, held, modules)
        splat = splat_call(code, index)
        hidden = splat ? [splat_operands(code, index); keywords] : keywords
        constant = constant_value(code, locals, head)
        if isnothing(constant)
            # Open callee can run any function with any operand.
            for operand in [operands; hidden], origin in origins(code, nargs, locals, operand)
                push!(fixed, (origin, UNKNOWN))
            end
            continue
        end
        callee = something(constant)
        # Callee methods whose signature can take known operand types; splat call has unknown operands after them.
        call = splat ? Tuple{Any, types..., Vararg{Any}} : Tuple{Any, types...}
        callees = Method[target for target in targets(callee) if typeintersect(call, target.sig) !== Union{}]
        if isempty(callees)
            # Higher-order call (`foreach(f, xs)`) can pass other operands to function operand: link 0 reaches any position.
            for (position, operand) in pairs(operands)
                value = local_value(code, locals, operand)
                resizing = value in RESIZE_FUNCTIONS || value === get!
                functions = resizing ? Method[] : function_methods(code, locals, operand, targets, closures)
                (resizing || !isempty(functions)) || continue
                for (other, reached) in pairs(held), origin in reached
                    other == position && continue
                    if resizing
                        push!(fixed, (origin, UNKNOWN))
                    else
                        push!(links, (origin, functions, 0))
                    end
                end
            end
            continue
        end
        # Splat and keyword value hide callee position.
        for operand in hidden, origin in origins(code, nargs, locals, operand)
            push!(fixed, (origin, UNKNOWN))
        end
        splat && continue
        for (position, reached) in pairs(held), origin in reached
            any(target -> vararg_position(target, position), callees) && push!(fixed, (origin, UNKNOWN))
            exact = filter(target -> !vararg_position(target, position), callees)
            isempty(exact) || push!(links, (origin, exact, position))
        end
    end
    for statement in code
        built = statement isa Expr && statement.head === :(=) ? statement.args[2] : statement
        built isa Expr || continue
        built.head === :new || continue
        type, held = built_type(code, built.args[1]), Vector{Origin}[origins(code, nargs, locals, operand) for operand in built.args[2:end]]
        push_field_uses!(fixed, type, held, modules)
        wrapper = Base.unwrap_unionall(type)
        wrapper isa DataType || continue
        haskey(closures, wrapper.name) || continue
        names = fieldnames(wrapper)
        for (index, reached) in pairs(held), origin in reached
            index > length(names) || push!(links, (origin, closures[wrapper.name], -index))
        end
    end
    return fixed, links
end

"""
Argument uses of lowered `bodies` (`lowered_bodies`) of package `modules` that need declared container type
(`ArgumentUse`), by method and position. Passes repeat until no use grows: each joins uses of package callee arguments,
including keyword bodies (`Core.kwcall`), and of closure fields into operands that reach them.
"""
function argument_uses(bodies::AbstractVector{<:Tuple{Method, AbstractVector{Any}, Type}}, modules::AbstractSet{Module})::IdDict{Method, Dict{Int, ArgumentUse}}
    exact, inexact, closures = IdDict{Type, Vector{Method}}(), Tuple{Type, Method}[], IdDict{Core.TypeName, Vector{Method}}()
    for (method, _, key) in bodies
        if isconcretetype(key)
            push!(get!(Vector{Method}, exact, key), method)
        else
            push!(inexact, (key, method))
        end
        wrapper = Base.unwrap_unionall(key)
        wrapper isa DataType && wrapper <: Function && push!(get!(Vector{Method}, closures, wrapper.name), method)
    end
    function targets(@nospecialize(callee::Any))::Vector{Method}
        isnothing(callee) && return Method[]
        type = Core.Typeof(callee)
        return [get(exact, type, Method[]); Method[method for (key, method) in inexact if type <: key]]
    end
    uses = IdDict{Method, Uses}(method => Uses() for (method, _, _) in bodies)
    links = Tuple{Uses, Origin, Vector{Method}, Int}[]
    for (method, code, _) in bodies
        fixed, own = use_steps(code, method, targets, closures, modules)
        foreach(((found, use),) -> record!(uses[method], first(found), use, last(found)), fixed)
        append!(links, [(uses[method], found, callees, key) for (found, callees, key) in own])
    end
    grown = true
    while grown
        grown = false
        for (into, (key, element), callees, link) in links, callee in callees
            # Link 0 reaches any position; negative link names closure field by position.
            use = link == 0 ? (any(((entry, found),) -> entry isa Int && (found.resized || found.elements_resized), uses[callee]) ? UNKNOWN : nothing) :
                get(uses[callee], link > 0 ? link : fieldnames(Base.unwrap_unionall(callee_type(callee)))[-link], nothing)
            isnothing(use) || (grown |= record!(into, key, use, element))
        end
    end
    return IdDict{Method, Dict{Int, ArgumentUse}}(method => Dict{Int, ArgumentUse}(key => use for (key, use) in found if key isa Int) for (method, found) in uses if any(key -> key isa Int, keys(found)))
end

"""Facts of loaded package `modules`, root module first, with method and struct sites in `files`."""
function package_facts(modules::AbstractVector{Module}, files::AbstractVector{SyntaxFile})::PackageFacts
    methods = module_methods(modules)
    sites = method_sites(methods, files)
    # Argument uses follow closures and keyword bodies, which have no site; `probed` reads site methods only.
    bodies = lowered_bodies(methods)
    sited = Base.IdSet{Method}(site.method for site in sites)
    return PackageFacts(modules, public_values(modules), sites, overwrites(sites), struct_sites(sites, files, modules), probed(filter(body -> first(body) in sited, bodies)), argument_uses(bodies, Set(modules)))
end

end
