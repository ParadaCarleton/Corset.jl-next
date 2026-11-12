"""
Spike S2: measure how TypedSyntax.jl maps typed-IR statements to source byte spans.

Run: `julia --startup-file=no --project=. measure.jl` from this directory.
Writes `out/statements.tsv`, `out/methods.tsv`, `out/cases.txt` and prints a summary.
"""

using TypedSyntax: TypedSyntax, tsn_and_mappings, code_typed1_tsn
using JuliaSyntax: JuliaSyntax, SyntaxNode, kind, children, is_leaf, byte_range, source_line, @K_str
using Core: MethodInstance, CodeInfo, SSAValue, GlobalRef
import Distances, DataStructures, JSON

include(joinpath(@__DIR__, "cases.jl"))

const CORPUS = (Cases, Distances, DataStructures, JSON)

"""Where definition source comes from: `codetracking` (TypedSyntax default) or `file` (own file parse)."""
const ROOT_SOURCE = Symbol(get(ENV, "S2_ROOT", "file"))

if ROOT_SOURCE === :file_lambda
    # Experiment: let TypedSyntax map closure and do-block bodies; both keep body at child 2.
    @eval TypedSyntax function collect_symbol_nodes(rootnode)
        rootnode = get_function_def(rootnode)
        is_function_def(rootnode) || kind(rootnode) in KSet"-> do" || error("expected function definition, got ", sourcetext(rootnode))
        return collect_symbol_nodes!(Dict{Any, Vector{typeof(rootnode)}}(), rootnode[2])
    end
end

"""Span result class of one statement. `foreign_line`: debuginfo line lies outside definition, e.g. macro body."""
@enum Mapping exact ambiguous line_only foreign_line missing

"""Return every method whose module lies inside `root`."""
function package_methods(root::Module)::Vector{Method}
    inside(mod::Module)::Bool = mod === root || (parentmodule(mod) !== mod && inside(parentmodule(mod)))
    found = Method[]
    Base.visit(m -> inside(m.module) && push!(found, m), Core.methodtable)
    return found
end

"""Pick a compiled specialization if one exists; else specialize on declared signature."""
function method_instance(m::Method)::MethodInstance
    specs = Base.specializations(m)
    isempty(specs) || return first(specs)
    sig = m.sig
    tvars = Any[]
    while sig isa UnionAll
        push!(tvars, sig.var)
        sig = sig.body
    end
    return Core.Compiler.specialize_method(m, sig, Core.svec(tvars...))
end

"""Classify method by how lowering made it."""
function method_category(m::Method, sourcetext::Union{AbstractString, Nothing})::Symbol
    name = string(m.name)
    Base.hasgenerator(m) && return :generated
    m.sig isa DataType && length(m.sig.parameters) > 0 && m.sig.parameters[1] === typeof(Core.kwcall) && return :kwcall
    occursin(r"^#[^#]+#\d+$", name) && return :kwbody
    startswith(name, "#") && return :closure
    sourcetext !== nothing && startswith(lstrip(sourcetext), "@") && return :macro_defined
    return :plain
end

"""Classify statement by what source construct produced it."""
function statement_kind(stmt)::Symbol
    stmt isa Expr && stmt.head === :(=) && (stmt = stmt.args[2])
    stmt isa Core.ReturnNode && return :return
    stmt isa Union{Core.GotoNode, Core.GotoIfNot} && return :control
    stmt isa Expr || return :other
    stmt.head === :new && return :new
    stmt.head === :call || return :other
    callee = stmt.args[1]
    callee isa GlobalRef || return :call
    callee.name in (:broadcasted, :materialize, :materialize!, :broadcasted_kwsyntax) && return :broadcast
    callee.name === :kwcall && return :kwcall
    callee.name in (:iterate, :indexed_iterate, :not_int, :(===)) && return :lowering_call
    return :call
end

"""Innermost macro call whose line range holds `line`, or empty string."""
function enclosing_macro(root::SyntaxNode, line::Integer)::String
    best = ""
    function walk(node::SyntaxNode)
        if kind(node) == K"macrocall"
            first_line = source_line(node)
            last_line = first_line + count(==('\n'), JuliaSyntax.sourcetext(node))
            first_line <= line <= last_line || return
            best = string(Expr(children(node)[1]))
        end
        is_leaf(node) || foreach(walk, children(node))
    end
    walk(root)
    return best
end

"""Byte offset of start of `line` (1-based) in `text`, 0-based."""
function line_offset(text::String, line::Integer)::Int
    offset = 0
    for _ in 2:line
        offset = findnext('\n', text, offset + 1)::Int
    end
    return offset
end

"""Byte offset before definition text in file; CodeTracking drops indentation of first line."""
function definition_offset(filetext::String, sourcetext::AbstractString, line::Integer)::Int
    offset = line_offset(filetext, line)
    indent = findnext(!isspace, filetext, offset + 1)::Int - offset - 1
    return startswith(sourcetext, ' ') ? offset : offset + indent
end

const FILE_TREES = Dict{String, SyntaxNode}()

"""Parse whole file once; byte ranges are file offsets."""
file_tree(file::String, filetext::String)::SyntaxNode =
    get!(() -> JuliaSyntax.parseall(SyntaxNode, filetext; filename = file, ignore_errors = true), FILE_TREES, file)

"""Last source line of node."""
last_line(node::SyntaxNode)::Int = source_line(node) + count(==('\n'), JuliaSyntax.sourcetext(node))

"""Find node defining `m` in file tree: innermost function-like node at `m.line`."""
function definition_node(tree::SyntaxNode, m::Method)::Union{SyntaxNode, Nothing}
    anonymous = startswith(string(m.name), "#") && !occursin(r"^#[^#]+#\d+$", string(m.name))
    best = nothing
    outer = nothing
    function walk(node::SyntaxNode)
        source_line(node) <= m.line <= last_line(node) || return
        outer === nothing && source_line(node) == m.line && (outer = node)
        lambda = kind(node) in (K"->", K"do")
        named = kind(node) == K"function" || TypedSyntax.is_function_def(node)
        if anonymous ? (lambda || named) : (named && !lambda && source_line(node) == m.line)
            best = node
        end
        is_leaf(node) || foreach(walk, children(node))
    end
    walk(tree)
    # Default constructors and macro-made methods have no function node; use first node on line.
    return something(best, outer, Some(nothing))
end

"""Return `(root, byte offset of root text, tree for macro attribution)` for method `m`."""
function locate_definition(m::Method, filetext::String)::Tuple{Union{SyntaxNode, Nothing}, Int, Union{SyntaxNode, Nothing}}
    if ROOT_SOURCE in (:file, :file_lambda)
        isempty(filetext) && return (nothing, 0, nothing)
        tree = file_tree(string(m.file), filetext)
        return (definition_node(tree, m), 0, tree)
    end
    definition = TypedSyntax.CodeTracking.definition(String, m)
    definition === nothing && return (nothing, 0, nothing)
    root = JuliaSyntax.parsestmt(SyntaxNode, definition[1]; filename = string(m.file), first_line = definition[2], ignore_errors = true)
    return (root, isempty(filetext) ? 0 : definition_offset(filetext, definition...), root)
end

"""Source line of statement `i` from debuginfo, with file; `(file, 0)` when unknown."""
function debug_line(src::CodeInfo, mi::MethodInstance, i::Int)::Tuple{String, Int}
    stack = Base.IRShow.buildLineInfoNode(src.debuginfo, mi, i)
    isempty(stack) && return (string(src.debuginfo.def), 0)
    entry = last(stack)
    return (string(entry.file), Int(entry.line))
end

"""Callee name of call statement, resolving SSA callee; `nothing` when not named call."""
function callee_name(src::CodeInfo, stmt)::Union{Symbol, Nothing}
    stmt isa Expr && stmt.head === :(=) && (stmt = stmt.args[2])
    stmt isa Expr && stmt.head === :call || return nothing
    callee = stmt.args[1]
    callee isa SSAValue && (callee = src.code[callee.id])
    return callee isa GlobalRef ? callee.name : nothing
end

"""Callee names that lowering inserts; source text need not spell them."""
const LOWERED_NAMES = Set([:getindex, :setindex!, :iterate, :indexed_iterate, :convert, :getproperty, :setproperty!,
    :typeassert, :isa, :(===), :not_int, :broadcasted, :materialize, :materialize!, :Generator, :tuple, :apply_type,
    :kwcall, :getfield, :isdefined, :_apply_iterate, :vect, :hcat, :vcat, :hvcat, :typed_vcat, :typed_hcat, :(:),
    :maybeview, :view, :dotview, :firstindex, :lastindex, :kwerr, :keys, :diff_names, :isempty, :_typeof_captured_variable,
    :fieldtype, :throw, :string, :cconvert, :unsafe_convert, :_expr, :merge, :structdiff, :pairs, :NamedTuple, :ifelse])

"""Callee text of call node with qualification and dots stripped."""
function node_callee(node)::String
    callee = JuliaSyntax.is_infix_op_call(node) ? children(node)[2] : children(node)[1]
    return last(split(lstrip(JuliaSyntax.sourcetext(callee), '.'), '.'))
end

"""Compare IR callee with callee spelled at mapped node."""
function callee_check(src::CodeInfo, stmt, node)::String
    name = callee_name(src, stmt)
    name === nothing && return "na"
    name in LOWERED_NAMES && return "lowered_name"
    kind(node) in (K"call", K"dotcall") || return "not_call_node"
    return node_callee(node) == string(name) ? "match" : "mismatch"
end

const STATEMENT_HEADER = join(["package", "method", "category", "stmt", "kind", "mapping", "macro", "debug_line_in_file", "callee_check", "file", "first_byte", "last_byte", "callee", "snippet"], '\t')

"""Map one method; append statement rows to `rows`; return timing and status."""
function measure_method!(rows::Vector{String}, package::Module, m::Method, cases_io::Union{IO, Nothing})::NamedTuple
    mi = method_instance(m)
    infer_seconds = @elapsed src_rt = try
        code_typed1_tsn(mi)
    catch err
        nothing
    end
    src_rt === nothing && return (; status = :infer_failed, infer_seconds, map_seconds = 0.0, category = method_category(m, nothing), statements = 0)
    src, rt = src_rt
    file = string(m.file)
    filetext = isfile(file) ? read(file, String) : ""
    map_seconds = @elapsed located = locate_definition(m, filetext)
    root, base, macro_root = located
    category = method_category(m, root === nothing ? nothing : JuliaSyntax.sourcetext(root))
    mappings = nothing
    if root !== nothing
        map_seconds += @elapsed mappings = try
            mappings, symtyps = TypedSyntax.map_ssas_to_source(src, mi, root, 0)
            TypedSyntax.TypedSyntaxNode(root, src, mappings, symtyps)
            mappings
        catch err
            nothing
        end
    end
    cases_io === nothing || println(cases_io, "\n== ", m, "  [", category, "]")
    for (i, stmt) in enumerate(src.code)
        nodes = mappings === nothing ? [] : mappings[i]
        dfile, dline = debug_line(src, mi, i)
        line_in_file = dline > 0 && dfile == file
        mapping = length(nodes) == 1 ? exact : length(nodes) > 1 ? ambiguous : line_in_file ? line_only : missing
        mapping == line_only && root !== nothing && !(source_line(root) <= dline <= last_line(root)) && (mapping = foreign_line)
        first_b, last_b = 0, 0
        check = "na"
        if mapping == exact
            node = only(nodes)
            range = byte_range(node)
            first_b, last_b = base + first(range), base + last(range)
            snippet = JuliaSyntax.sourcetext(node)
            # Span must point at same bytes in file as in parsed definition.
            codeunits(filetext)[first_b:last_b] == codeunits(snippet) || (mapping = missing; check = "offset_mismatch")
            mapping == exact && (check = callee_check(src, stmt, node))
        end
        macro_name = macro_root === nothing || dline <= 0 ? "" : enclosing_macro(macro_root, dline)
        push!(rows, join([package, m.name, category, i, statement_kind(stmt), mapping, macro_name, line_in_file, check, file, first_b, last_b, something(callee_name(src, stmt), ""), mapping == exact ? escape_string(first(JuliaSyntax.sourcetext(only(nodes)), 80), "\t") : ""], '\t'))
        if cases_io !== nothing
            text = mapping == exact ? repr(JuliaSyntax.sourcetext(only(nodes))) : mapping == ambiguous ? "$(length(nodes)) candidates" : "line $dline"
            println(cases_io, rpad("  %$i $(statement_kind(stmt))", 22), rpad(string(mapping), 10), rpad(macro_name, 10), text, "    ", stmt)
        end
    end
    status = root === nothing ? :no_definition : mappings === nothing ? :map_failed : :ok
    return (; status, infer_seconds, map_seconds, category, statements = length(src.code))
end

function main()::Nothing
    precompile(Cases.generated_sum, (NTuple{3, Float64},))
    outdir = mkpath(joinpath(@__DIR__, "out", string(ROOT_SOURCE)))
    rows = String[]
    method_rows = ["package\tmethod\tcategory\tstatus\tstatements\tinfer_seconds\tmap_seconds"]
    open(joinpath(outdir, "cases.txt"), "w") do cases_io
        for package in CORPUS
            methods = package_methods(package)
            # Warm up compiler so timing excludes first-call compilation.
            measure_method!(String[], package, first(methods), nothing)
            for m in methods
                result = measure_method!(rows, package, m, package === Cases ? cases_io : nothing)
                push!(method_rows, join([package, m.name, result.category, result.status, result.statements, result.infer_seconds, result.map_seconds], '\t'))
            end
        end
    end
    write(joinpath(outdir, "statements.tsv"), join([STATEMENT_HEADER; rows], '\n'))
    write(joinpath(outdir, "methods.tsv"), join(method_rows, '\n'))
    return nothing
end

abspath(PROGRAM_FILE) == @__FILE__() && main()
