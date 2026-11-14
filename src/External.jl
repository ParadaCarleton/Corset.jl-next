"""
`external` stage: run external checks on loaded package; keep their output as facts.

`Test.detect_ambiguities` runs on package modules, as Aqua.jl does. Pair with method outside package methods
(other module, generated method, file outside analyzed files) drops.
Aqua.jl offers piracy check only as `@test`, so stage calls internal `Aqua.Piracy.is_pirate`; compat pins minor version.
ExplicitImports.jl reports non-public qualified accesses and imports, names bare `using` brings, and uses of explicitly
imported names; access inside package passes. One ExplicitImports.jl parse serves every check.
"""
module External

using ..Facts: ExternalFacts, PackageFacts, MethodSite, InternalAccess, BareUsing, ExplicitImport, SyntaxFile, SyntaxNode, Span, Precision
using ..Facts: ancestors, children_of, definition_name, descendants, forms, kind_name, source, span
using ..Package: line_starts
using Aqua: Aqua
using ExplicitImports: ExplicitImports
using Test: Test

"""Source order of method site: file, first byte, then signature text for sites on one line."""
source_order(site::MethodSite)::Tuple{String, Int, String} = (site.span.file, site.span.first_byte, string(site.method.sig))

"""
Pairs of `package` method sites `Test.detect_ambiguities` reports: earlier site first, pairs sorted by later site.
It returns pair of methods on one line in both orders; each pair keeps one entry.
"""
function ambiguities(package::PackageFacts)::Vector{Tuple{MethodSite, MethodSite}}
    sites = IdDict{Method, MethodSite}(site.method => site for site in package.methods)
    found = Tuple{MethodSite, MethodSite}[]
    for (one, other) in Test.detect_ambiguities(package.modules...)
        haskey(sites, one) && haskey(sites, other) || continue
        earlier, later = sort([sites[one], sites[other]]; by = source_order)
        push!(found, (earlier, later))
    end
    return sort!(unique!(found); by = pair -> (source_order(last(pair)), source_order(first(pair))))
end

"""Types and functions package `modules` define, by binding; Aqua.jl gives each extension own package id, so extensions need list."""
function owned(modules::Vector{Module})::Vector{Union{Function, Type}}
    package, found = Set(modules), Union{Function, Type}[]
    for mod in modules, name in names(mod; all = true)
        isdefined(mod, name) || continue
        binding = getglobal(mod, name)
        # `Union` alias has no parent module; Aqua.jl reads union members one by one.
        definition = binding isa Function || Base.unwrap_unionall(binding) isa DataType
        definition && parentmodule(binding) in package && push!(found, binding)
    end
    return found
end

"""Sites of `package` methods Aqua.jl calls type piracy: package owns neither function nor any argument type."""
function piracies(package::PackageFacts)::Vector{MethodSite}
    own = owned(package.modules)
    return filter(site -> Aqua.Piracy.is_pirate(site.method; treat_as_own = own), package.methods)
end

"""
Span of `name` at ExplicitImports.jl `location` (`path:line:column`; column counts characters) in `files` by path.
Macro location points after `@`. `nothing` outside analyzed files; location away from name throws.
"""
function location_span(location::String, name::String, files::Dict{String, SyntaxFile})::Union{Nothing, Span}
    path, line, column = rsplit(location, ':'; limit = 3)
    file = get(files, path, nothing)
    isnothing(file) && return nothing
    line_start = line_starts(file.text)[parse(Int, line)]
    start = nextind(file.text, line_start - 1, parse(Int, column)) - startswith(name, '@')
    startswith(SubString(file.text, start), name) || error("ExplicitImports.jl location $location does not point at `$name`")
    return Span(path, start, start + ncodeunits(name) - 1, Precision.exact)
end

"""`accesses` in source order, each chain merged: segment that follows `.` right after earlier segment joins it."""
function merged(accesses::Vector{InternalAccess}, files::Dict{String, SyntaxFile})::Vector{InternalAccess}
    found = InternalAccess[]
    for access in sort(accesses; by = access -> (access.span.file, access.span.first_byte))
        previous = isempty(found) ? nothing : last(found)
        same_file = !isnothing(previous) && previous.span.file == access.span.file
        if same_file && SubString(files[access.span.file].text, previous.span.last_byte + 1, access.span.first_byte - 1) == "."
            span = Span(access.span.file, previous.span.first_byte, access.span.last_byte, Precision.exact)
            found[end] = InternalAccess(previous.owner, "$(previous.name).$(access.name)", span, previous.imported)
        else
            push!(found, access)
        end
    end
    return found
end

"""ExplicitImports.jl parse of root module file, by path, as its private `file_analysis` keyword takes it."""
const Analyses = Dict{String, ExplicitImports.FileAnalysis}

"""
Accesses of package to names other modules neither export nor declare `public`, in analyzed `files`. Module that
ExplicitImports.jl cannot analyze fully (dynamic `include`, module macro writes) gives no import rows.
"""
function internal_accesses(package::PackageFacts, files::Vector{SyntaxFile}, analyses::Analyses)::Vector{InternalAccess}
    root, by_path = first(package.modules), Dict(file.path => file for file in files)
    found = InternalAccess[]
    for (_, rows) in ExplicitImports.improper_qualified_accesses(root, pathof(root); file_analysis = analyses), row in rows
        span = location_span(row.location, string(row.name), by_path)
        row.self_qualified || isnothing(span) || push!(found, InternalAccess(row.accessing_from, string(row.name), span, false))
    end
    for (_, rows) in ExplicitImports.improper_explicit_imports(root, pathof(root); file_analysis = analyses), row in something(rows, ())
        span = location_span(row.location, string(row.name), by_path)
        row.public_import || isnothing(span) || push!(found, InternalAccess(row.importing_from, string(row.name), span, true))
    end
    return merged(found, by_path)
end

"""Name of innermost `module` form around `node` of `file`; `nothing` at top level of included file."""
function enclosing_module(file::SyntaxFile, node::SyntaxNode)::Union{Nothing, Symbol}
    index = findfirst(ancestor -> kind_name(ancestor) == "module", ancestors(node))
    return isnothing(index) ? nothing : Symbol(source(file, definition_name(ancestors(node)[index])))
end

"""
Module path of bare `using` in `files` that brings `exporter` into module `mod`: path ends in exporter name, and
statement sits in `module` form named like `mod`, else at top level of included file. First in file order.
"""
function bare_statement(mod::Module, exporter::Module, files::Vector{SyntaxFile})::Union{Nothing, Tuple{SyntaxFile, SyntaxNode}}
    inside, included = Tuple{SyntaxFile, SyntaxNode}[], Tuple{SyntaxFile, SyntaxNode}[]
    for file in files, statement in forms(file, "using"), path in children_of(statement)
        # `using X: a` holds one `:` child; bare `using A, B` holds one `importpath` per module.
        kind_name(path) == "importpath" && source(file, last(children_of(path))) == string(nameof(exporter)) || continue
        owner = enclosing_module(file, statement)
        owner === nameof(mod) && push!(inside, (file, path))
        isnothing(owner) && push!(included, (file, path))
    end
    return isempty(inside) ? (isempty(included) ? nothing : first(included)) : first(inside)
end

"""
Names package modules reach through bare `using`, one entry per statement, in source order: ExplicitImports.jl names
them, syntax finds statement. Names of `Base`, `Core` and package pass. Statement outside analyzed `files`, and module
ExplicitImports.jl cannot analyze fully, give no entry.
"""
function bare_usings(package::PackageFacts, files::Vector{SyntaxFile}, analyses::Analyses)::Vector{BareUsing}
    root, by_path = first(package.modules), Dict(file.path => file for file in files)
    found = BareUsing[]
    for (mod, rows) in ExplicitImports.explicit_imports(root, pathof(root); file_analysis = analyses)
        isnothing(rows) && continue
        for exporter in unique(reduce(vcat, (row.exporters for row in rows); init = Module[]))
            statement = bare_statement(mod, exporter, files)
            isnothing(statement) && continue
            # Bare `using X` binds `X` too; fix always keeps it, so it is no brought name.
            brought = [row for row in rows if exporter in row.exporters && row.name !== nameof(exporter)]
            uses = Tuple{Symbol, Span}[]
            for row in brought
                use = location_span(row.location, string(row.name), by_path)
                isnothing(use) || push!(uses, (row.name, use))
            end
            sort!(uses; by = ((_, use),) -> (use.file, use.first_byte))
            push!(found, BareUsing(exporter, span(statement...), sort!([row.name for row in brought]), uses))
        end
    end
    return sort!(found; by = imported -> (imported.statement.file, imported.statement.first_byte))
end

"""`using` or `import` statement of `file` that holds `name`."""
statement_of(file::SyntaxFile, name::Span)::SyntaxNode =
    only(node for kind in ("using", "import") for node in forms(file, kind) if span(file, node).first_byte <= name.first_byte <= span(file, node).last_byte)

"""
Explicit import statements (`using X: a`, `import X: a`, `import X`) in analyzed `files`, each with global uses of names
it binds in its module, in source order. Statement with `as`, statement or use outside `files`, and module
ExplicitImports.jl cannot analyze fully give no entry.
"""
function explicit_imports(analysis::ExplicitImports.FileAnalysis, files::Vector{SyntaxFile})::Vector{ExplicitImport}
    by_path, rows = Dict(file.path => file for file in files), analysis.per_usage_info
    # First use of name in scope decides whether name is global there; later uses carry no verdict.
    global_in = Set((row.name, map(objectid, row.scope_path)) for row in rows if row.external_global_name === true)
    statements = Dict{Span, Tuple{Vector{Symbol}, Vector{Symbol}}}()
    for row in rows
        row.import_type in (:import_RHS, :blanket_using) && row.module_path in analysis.untainted_modules || continue
        name = location_span(row.location, string(row.name), by_path)
        isnothing(name) && continue
        statement = statement_of(by_path[name.file], name)
        any(node -> kind_name(node) == "as", descendants(statement)) && continue
        push!(last(get!(statements, span(by_path[name.file], statement), (row.module_path, Symbol[]))), row.name)
    end
    found = ExplicitImport[]
    for (statement, (module_path, names)) in statements
        uses, outside = Tuple{Symbol, Span}[], false
        for row in rows
            row.name in names && row.module_path == module_path && row.import_type == :not_import && isnothing(row.qualified_by) || continue
            # ExplicitImports.jl marks named-tuple key or field name after global use as later use; neither reads name.
            !row.kwarg_name && !row.struct_field_name && (row.name, map(objectid, row.scope_path)) in global_in || continue
            use = location_span(row.location, string(row.name), by_path)
            isnothing(use) ? (outside = true) : push!(uses, (row.name, use))
        end
        # Use outside analyzed files (`corset check src/one.jl`) would make import look unused or misplaced.
        outside || push!(found, ExplicitImport(statement, names, sort!(uses; by = ((_, use),) -> (use.file, use.first_byte))))
    end
    return sort!(found; by = imported -> (imported.statement.file, imported.statement.first_byte))
end

"""External facts of loaded `package` with analyzed `files`."""
function external_facts(package::PackageFacts, files::Vector{SyntaxFile})::ExternalFacts
    path = pathof(first(package.modules))
    analyses = Analyses(path => ExplicitImports.get_names_used(path))
    return ExternalFacts(
        ambiguities(package), piracies(package), internal_accesses(package, files, analyses), bare_usings(package, files, analyses),
        explicit_imports(analyses[path], files),
    )
end

end
