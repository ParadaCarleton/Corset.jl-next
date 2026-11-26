"""
`push-loop` (F117): loop grows empty array one `push!` per iteration.

## Description
Reports loop whose body only pushes one value onto array that statement before loop assigns empty.
Push may sit under one `if` without `else`, or after `&&`. Loop has no early exit.

## Rationale
Loop states result only through pushes; comprehension states it in one expression.
Comprehension over source of known length allocates result once; `push!` grows and copies storage as loop runs.

## Example
```julia
squares = Float64[]
for x in xs
    push!(squares, x^2)
end
```

## Alternative
```julia
squares = Float64[x^2 for x in xs]
```

## Limitations
Empty array: `T[]`, `[]`, `Vector{T}()` or `Vector{T}(undef, 0)`. `T` is curly type, `where` parameter, type that
analyzed files define, or Base type: `r[]` of other name reads `Ref`.
Type name counts as Base type only when no analyzed file binds its leftmost name (`bound_names`): package can define own
`String` or `Base`. Module that `using` loads can export same name; it clashes with Base export unless package has
`baremodule`.
Loop with several iteration specs passes: comprehension over them gives matrix.
Loop passes when comprehension would capture parameter typed `Type`, `DataType`, `UnionAll` or `Function`: closure
compiles once per captured value.
Filter comprehension iterates source step by step, as loop does: its fix is `safe`. Other comprehension takes length
of source first, so method that loop runs (call, `getindex`, `convert` in `push!`) can resize source and change result.
Fix is `safe` when no code can change length of source: parameter typed `String` or tuple, or range over bits numbers
(`1:n` with `n::Int`, `span::UnitRange{Int}`). Method must never rebind parameter. Range over `BigInt` changes length
when its bound changes in place. Other source gets manual fix; comprehension over matrix also gives matrix.
Fix is manual when comment sits in replaced code, or when comprehension captures local that function binds twice:
closure boxes it. Comprehension runs before its assignment, so fix is manual when closure or generator in same scope
names array (top-level method of any analyzed file for global array), or `try` around loop can read partial array after throw.
"""
module PushLoop

using ...Facts

const NAME = Symbol("push-loop")

"""Kinds whose nodes leave loop early."""
const EXITS = ("return", "break", "continue")

"""Kinds that open scope whose captured locals closure can box."""
const SCOPES = ("function", "->", "do", "let", "macro")

"""Names that `where` clauses of signature `node` bind: `T` of `where T`, `where {T <: Real, S}`."""
function where_names(node::SyntaxNode)::Vector{String}
    kind_name(node) in ("where", "::") || return String[]
    found = where_names(children_of(node)[1])
    kind_name(node) == "where" || return found
    for clause in children_of(node)[2:end], parameter in (kind_name(clause) == "braces" ? children_of(clause) : [clause])
        name = kind_name(parameter) in ("<:", ">:") ? children_of(parameter)[1] : parameter
        isnothing(identifier_name(name)) || push!(found, identifier_name(name))
    end
    return found
end

"""Whether Base binds `name` to type."""
base_type(name::String)::Bool = (symbol = Symbol(name); isdefined(Base, symbol) && !Base.isdeprecated(Base, symbol) && getglobal(Base, symbol) isa Type)

"""
Whether `node` names type: curly type, `where` parameter of enclosing method, type `defined` in analyzed files, or Base
type whose name is not in `bound`.
"""
function type_name(node::SyntaxNode, defined::AbstractSet{String}, bound::AbstractSet{String})::Bool
    kind_name(node) == "curly" && return true
    name = identifier_name(node)
    isnothing(name) && return false
    name in defined && return true
    any(ancestor -> kind_name(ancestor) == "function" && name in where_names(children_of(ancestor)[1]), ancestors(node)) && return true
    return !(name in bound) && base_type(name)
end

"""
Element type text of empty array `node`: `T[]` and `Vector{T}()` give `T`; `[]` and `Vector()` give `Any`. `nothing`
for other value.
"""
function element_text(file::SyntaxFile, node::SyntaxNode, defined::AbstractSet{String}, bound::AbstractSet{String})::Union{Nothing, String}
    kind, children = kind_name(node), children_of(node)
    kind == "vect" && isempty(children) && return "Any"
    kind == "ref" && length(children) == 1 && type_name(children[1], defined, bound) && return source(file, children[1])
    kind == "call" || return nothing
    arguments = call_arguments(node)
    (isempty(arguments) || (length(arguments) == 2 && identifier_name(arguments[1]) == "undef" && source(file, arguments[2]) == "0")) || return nothing
    callee = callee_node(node)
    trusted_name(callee, bound) == "Vector" && return "Any"
    kind_name(callee) == "curly" && length(children_of(callee)) == 2 && trusted_name(children_of(callee)[1], bound) == "Vector" || return nothing
    return source(file, children_of(callee)[2])
end

"""Name node that assignment target `node` binds: `out` of `out` and of `out::Vector{Int}`."""
function target_name(node::SyntaxNode)::Union{Nothing, SyntaxNode}
    kind_name(node) == "::" && return target_name(children_of(node)[1])
    return isnothing(identifier_name(node)) ? nothing : node
end

"""Push statement `node` and filter condition: `push!(out, v)`, `if c; push!(out, v); end` or `c && push!(out, v)`."""
function pushed(node::SyntaxNode)::Union{Nothing, Tuple{SyntaxNode, Union{Nothing, SyntaxNode}}}
    kind, children = kind_name(node), children_of(node)
    call_head(node) == "push!" && return (node, nothing)
    kind == "&&" && length(children) == 2 && call_head(children[2]) == "push!" && return (children[2], children[1])
    kind == "if" && length(children) == 2 || return nothing
    body = children_of(children[2])
    return length(body) == 1 && call_head(body[1]) == "push!" ? (body[1], children[1]) : nothing
end

"""
Names that any file of package binds: binding sites other than struct fields, `where` parameters, and names in `using`
and `import` statements. With `baremodule`, also each `TYPE_NAMES` name Core does not export: no implicit `using Base`
clashes with name that `using` supplies.
"""
function bound_names(files::AbstractVector{SyntaxFile})::Set{String}
    found = Set{String}()
    for file in files
        union!(found, (identifier_name(site.name) for site in file.bindings if site.kind != BindingKind.field && !isnothing(identifier_name(site.name))))
        union!(found, names_in([forms(file, "using"); forms(file, "import")]))
        foreach(definition -> union!(found, where_names(children_of(definition)[1])), forms(file, "function"))
    end
    bare = any(node -> Facts.JS.has_flags(node, Facts.JS.BARE_MODULE_FLAG), (node for file in files for node in forms(file, "module")))
    bare && union!(found, (name for name in TYPE_NAMES if !Base.isexported(Core, Symbol(name))))
    return found
end

"""Leftmost name of dotted path `node`: `Base` of `Base.Iterators.Stateful`, `Int` of `Int`."""
root_name(node::SyntaxNode)::Union{Nothing, String} = kind_name(node) == "." ? root_name(children_of(node)[1]) : identifier_name(node)

"""Base name that `node` names (`base_name`) when `bound` lacks its leftmost name: package can define own `Base`."""
trusted_name(node::SyntaxNode, bound::AbstractSet{String})::Union{Nothing, String} = root_name(node) in bound ? nothing : base_name(node)

"""Identifier names in `nodes` and their descendants."""
names_in(nodes::AbstractVector{SyntaxNode})::Set{String} = Set(identifier_name(leaf) for node in nodes for leaf in descendants(node) if !isnothing(identifier_name(leaf)))

"""
First byte of each binding of each name in `file`, sorted: parameters and assignments once, updates (`x += 1`) twice,
since update rebinds name it reads.
"""
function binding_positions(file::SyntaxFile)::Dict{String, Vector{Int}}
    positions = Dict{String, Vector{Int}}()
    for site in file.bindings
        site.kind in (BindingKind.parameter, BindingKind.assignment) || continue
        push!(get!(Vector{Int}, positions, identifier_name(site.name)), span(file, site.name).first_byte)
    end
    for update in forms(file, "op=")
        name, first_byte = identifier_name(children_of(update)[1]), span(file, update).first_byte
        isnothing(name) || append!(get!(Vector{Int}, positions, name), (first_byte, first_byte))
    end
    foreach(sort!, values(positions))
    return positions
end

"""Bindings of `name` inside `root`, from `binding_positions`."""
function binding_count(file::SyntaxFile, positions::AbstractDict{String, <:AbstractVector{<:Integer}}, root::SyntaxNode, name::String)::Int
    found, whole = get(positions, name, Int[]), span(file, root)
    return max(0, searchsortedlast(found, whole.last_byte) - searchsortedfirst(found, whole.first_byte) + 1)
end

"""Outermost scope around `node` whose locals closure can capture; `nothing` at top level, where names are globals."""
scope_root(node::SyntaxNode)::Union{Nothing, SyntaxNode} = (scopes = filter(ancestor -> kind_name(ancestor) in SCOPES, ancestors(node)); isempty(scopes) ? nothing : last(scopes))

"""Captured `names` that scope `root` binds twice: comprehension closure boxes them. Closure never boxes global."""
boxed(file::SyntaxFile, positions::AbstractDict{String, <:AbstractVector{<:Integer}}, root::Union{Nothing, SyntaxNode}, names::AbstractSet{String})::Vector{String} =
    isnothing(root) ? String[] : sort!([name for name in names if binding_count(file, positions, root, name) > 1])

"""Kinds of code that can run after it is defined: closure and generator bodies."""
const DEFERRED = ("function", "->", "do", "generator")

"""Deferred code nodes (`DEFERRED`) inside function by scope root (`scope_root`), then by name they read."""
const Deferred = IdDict{SyntaxNode, Dict{String, Vector{SyntaxNode}}}

"""Deferred code of `file` by scope root and name it reads."""
function deferred_names(file::SyntaxFile)::Deferred
    found = Deferred()
    for kind in DEFERRED, node in forms(file, kind)
        root = scope_root(node)
        # Global target always gets manual fix (`comprehension_fix`): top-level code needs no index.
        isnothing(root) && continue
        readers = get!(Dict{String, Vector{SyntaxNode}}, found, root)
        foreach(name -> push!(get!(Vector{SyntaxNode}, readers, name), node), names_in([node]))
    end
    return found
end

"""Whether deferred code in scope `root` outside `loop` names `target`; code around loop runs loop and is no reader."""
function read_elsewhere(index::Deferred, root::SyntaxNode, loop::SyntaxNode, target::String)::Bool
    around = ancestors(loop)
    return any(reader -> !any(ancestor -> ancestor === reader, around), get(get(index, root, Dict{String, Vector{SyntaxNode}}()), target, SyntaxNode[]))
end

"""Names that `global` declarations of `file` name, by scope root (`scope_root`) of declaration."""
function declared_globals(file::SyntaxFile)::IdDict{SyntaxNode, Set{String}}
    found = IdDict{SyntaxNode, Set{String}}()
    for node in forms(file, "global")
        root = scope_root(node)
        isnothing(root) || union!(get!(Set{String}, found, root), names_in([node]))
    end
    return found
end

"""Whether `target` names global in scope `root` of loop: loop at top level, or `global` declaration in scope names it."""
global_target(globals::IdDict{SyntaxNode, Set{String}}, root::Union{Nothing, SyntaxNode}, target::String)::Bool =
    isnothing(root) || target in get(globals, root, Set{String}())

"""Whether `try` between `loop` and scope `root` can catch throw inside loop."""
function guarded(loop::SyntaxNode, root::Union{Nothing, SyntaxNode})::Bool
    for ancestor in ancestors(loop)
        ancestor === root && return false
        kind_name(ancestor) == "try" && return true
    end
    return false
end

"""
Per-file indexes: binding first bytes by name (`binding_positions`), names deferred code reads (`deferred_names`), names
`global` declarations name (`declared_globals`). Package-wide: names any file binds (`bound_names`).
"""
struct FileIndex
    positions::Dict{String, Vector{Int}}
    deferred::Deferred
    globals::IdDict{SyntaxNode, Set{String}}
    bound::Set{String}
end

"""Annotation heads whose values iterate as 1-based vector or without shape: comprehension over them gives `Vector`."""
const ONE_BASED = ("Vector", "String", "AbstractString", "Set", "Dict", "UnitRange", "StepRange", "Tuple", "NTuple")

"""`ONE_BASED` heads of values whose length no code can change: comprehension over them matches loop."""
const FIXED = ("String", "Tuple", "NTuple")

"""Range heads whose length follows from their bounds."""
const RANGES = ("UnitRange", "StepRange")

"""Names of bits number types: no code changes their values in place."""
const BITS = ("Bool", "Char", "Int", "Int8", "Int16", "Int32", "Int64", "Int128", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "Float16", "Float32", "Float64")

"""Annotation of parameter `name` in signature `parts` of method; `nothing` when none binds `name` with type."""
function parameter_annotation(parts::NamedTuple, name::String)::Union{Nothing, SyntaxNode}
    for argument in parts.arguments, parameter in (kind_name(argument) == "parameters" ? children_of(argument) : [argument])
        node = kind_name(parameter) in ("=", "kw") ? children_of(parameter)[1] : parameter
        kind_name(node) == "::" && length(children_of(node)) == 2 && identifier_name(children_of(node)[1]) == name && return children_of(node)[2]
    end
    return nothing
end

"""Annotation heads of values closure type records exactly (`Type{Int}`, `typeof(sin)`)."""
const PER_VALUE = ("Type", "DataType", "UnionAll", "Function")

"""Names `trusted_name` resolves to Base or Core: type names this rule reads, and `Base` itself."""
const TYPE_NAMES = (ONE_BASED..., BITS..., PER_VALUE..., "Base")

"""
Whether one of `names` is parameter of method around `loop` with `PER_VALUE` annotation. Method compiles once for all
such values; comprehension closure capturing one compiles once per value.
"""
function captures_per_value(loop::SyntaxNode, names::AbstractSet{String}, bound::AbstractSet{String})::Bool
    for ancestor in ancestors(loop)
        parts = kind_name(ancestor) == "function" ? signature(ancestor) : nothing
        isnothing(parts) && continue
        for name in names
            annotation = parameter_annotation(parts, name)
            isnothing(annotation) && continue
            annotation_head(annotation, bound) in PER_VALUE && return true
        end
    end
    return false
end

"""Annotation of parameter `node` of method around `loop`, when method never rebinds it; else `nothing`."""
function stable_annotation(file::SyntaxFile, positions::AbstractDict{String, <:AbstractVector{<:Integer}}, loop::SyntaxNode, node::SyntaxNode)::Union{Nothing, SyntaxNode}
    name = identifier_name(node)
    method = findfirst(ancestor -> kind_name(ancestor) == "function", ancestors(loop))
    (isnothing(name) || isnothing(method)) && return nothing
    definition = ancestors(loop)[method]
    parts = signature(definition)
    annotation = isnothing(parts) ? nothing : parameter_annotation(parts, name)
    return !isnothing(annotation) && binding_count(file, positions, definition, name) == 1 ? annotation : nothing
end

"""Head name of `annotation` (`trusted_name`): `Vector` for `Vector{Int}`."""
annotation_head(annotation::SyntaxNode, bound::AbstractSet{String})::Union{Nothing, String} = trusted_name(kind_name(annotation) == "curly" ? children_of(annotation)[1] : annotation, bound)

"""Whether `annotation` names `BITS` type without parameters (`trusted_name`): `MutableInteger{Int}` is not."""
bits_type(annotation::SyntaxNode, bound::AbstractSet{String})::Bool = kind_name(annotation) != "curly" && trusted_name(annotation, bound) in BITS

"""
Whether `node` is number or character literal of bits type, or parameter typed `BITS` that method around `loop` never
rebinds. Integer literal past `Int128` parses as mutable `BigInt`.
"""
function bits_value(file::SyntaxFile, index::FileIndex, loop::SyntaxNode, node::SyntaxNode)::Bool
    kind_name(node) == "char" && return true
    kind_name(node) in Facts.LITERAL_LEAVES && return isbits(node.val)
    annotation = stable_annotation(file, index.positions, loop, node)
    return !isnothing(annotation) && bits_type(annotation, index.bound)
end

"""`ONE_BASED` head that tells how loop `source` iterates: `UnitRange` for range literal, or head of `stable_annotation`."""
function source_head(file::SyntaxFile, index::FileIndex, loop::SyntaxNode, source::SyntaxNode)::Union{Nothing, String}
    call_head(source) == ":" && return "UnitRange"
    annotation = stable_annotation(file, index.positions, loop, source)
    head = isnothing(annotation) ? nothing : annotation_head(annotation, index.bound)
    return head in ONE_BASED ? head : nothing
end

"""
Whether no code can change length of loop `source`: `FIXED` parameter, range parameter over `BITS` types, or range
literal whose bounds are each `bits_value`. Range over `BigInt` or mutable `Integer` changes length when bound changes.
"""
function fixed_length(file::SyntaxFile, index::FileIndex, loop::SyntaxNode, source::SyntaxNode)::Bool
    call_head(source) == ":" && return all(limit -> bits_value(file, index, loop, limit), call_arguments(source))
    annotation = stable_annotation(file, index.positions, loop, source)
    isnothing(annotation) && return false
    head = annotation_head(annotation, index.bound)
    return head in FIXED || (head in RANGES && kind_name(annotation) == "curly" && all(parameter -> bits_type(parameter, index.bound), children_of(annotation)[2:end]))
end

"""
Fix replacing empty array `empty` through `loop` with comprehension `text` that fills `target`: `safe` for filter or
source of `fixed_length`, else manual. Filter iterates source step by step, as loop does; other comprehension takes
length of source first, and any call, `getindex` or `convert` in loop can change it. Manual when comment sits in
replaced code, closure names `target` (comprehension runs before assignment, so closure would see old value), `try`
can see partial `target`, or closure boxes captured local. Global `target` (`global_target`) gets manual fix: code
can read global by computed name, as `getglobal(@__MODULE__, Symbol("out"))` does, which no name index sees.
"""
function comprehension_fix(file::SyntaxFile, index::FileIndex, target::String, empty::SyntaxNode, loop::SyntaxNode, text::String, filtered::Bool, source_node::SyntaxNode, captured::AbstractSet{String})::Fix
    replaced = Span(file.path, span(file, empty).first_byte, span(file, loop).last_byte, Precision.exact)
    isempty(comments_in(file, replaced.first_byte:replaced.last_byte)) || return manual_fix("replace loop with `$text`; keep its comments by hand")
    root = scope_root(loop)
    global_target(index.globals, root, target) && return manual_fix("replace loop with `$text` unless code that runs in loop reads global `$target`; it would see old `$target`")
    read_elsewhere(index.deferred, root, loop, target) && return manual_fix("replace loop with `$text` unless function that names `$target` runs in loop; it would see old `$target`")
    guarded(loop, root) && return manual_fix("replace loop with `$text` unless `try` around loop reads `$target`; it would see old `$target` after throw")
    names = boxed(file, index.positions, root, captured)
    isempty(names) || return manual_fix("replace loop with `$text` once $(join(("`$name`" for name in names), ", ")) gets one binding; closure boxes local bound twice")
    (filtered || fixed_length(file, index, loop, source_node)) && return Fix("replace loop with comprehension", [Edit(replaced, text)], Tier.safe)
    shape = isnothing(source_head(file, index, loop, source_node)) ? " and keeps its shape and axes" : ""
    return manual_fix("replace loop with `$(text)` unless loop changes length of `$(source(file, source_node))`; comprehension takes its length first$shape")
end

"""Finding for `loop` when `assignment` before it assigns empty array that loop fills; `index` of `file`."""
function push_finding(file::SyntaxFile, index::FileIndex, assignment::SyntaxNode, loop::SyntaxNode, defined::AbstractSet{String})::Union{Nothing, Finding}
    kind_name(assignment) == "=" || return nothing
    target, empty = target_name(children_of(assignment)[1]), children_of(assignment)[2]
    isnothing(target) && return nothing
    element = element_text(file, empty, defined, index.bound)
    specs, body = children_of(children_of(loop)[1]), children_of(children_of(loop)[2])
    (isnothing(element) || length(specs) != 1 || length(body) != 1) && return nothing
    found = pushed(body[1])
    isnothing(found) && return nothing
    push, condition = found
    arguments = call_arguments(push)
    length(arguments) == 2 && identifier_name(arguments[1]) == identifier_name(target) && kind_name(arguments[2]) ∉ ("...", "=", "parameters") || return nothing
    value, spec = arguments[2], only(specs)
    identifier_name(target) in names_in(isnothing(condition) ? [value, spec] : [value, spec, condition]) && return nothing
    any(node -> kind_name(node) in EXITS || (kind_name(node) == "macrocall" && macro_name(file, node) in ("@goto", "@label")), descendants(children_of(loop)[2])) && return nothing
    filter_text = isnothing(condition) ? "" : " if $(operand(file, condition, CONDITION))"
    text = "$element[$(operand(file, value, :(=>))) for $(source(file, spec))$filter_text]"
    loop_names = names_in([children_of(spec)[1]])
    captured = setdiff(names_in(isnothing(condition) ? [value] : [value, condition]), loop_names)
    captures_per_value(loop, captured, index.bound) && return nothing
    name = identifier_name(target)
    return finding(
        NAME, file, push; kind = isnothing(condition) ? :growth : :filtered, confidence = Confidence.definite,
        message = "loop builds `$name` one `push!` at a time", label = isnothing(condition) ? "pushes once per iteration" : "pushes when filter holds",
        causes = [Label(span(file, assignment), "starts empty here")],
        why = isnothing(condition) ? "`push!` grows storage as loop runs; comprehension sizes result once and states it in one expression" :
            "comprehension states filter and value in one expression; loop spreads result over pushes",
        fix = comprehension_fix(file, index, name, empty, loop, text, !isnothing(condition), children_of(spec)[2], captured),
    )
end

"""Findings for loops that fill array assigned empty right before them, one `push!` per iteration."""
function findings(facts::FactSet)::Vector{Finding}
    defined = Set{String}(something(identifier_name(definition_name(node)), "") for file in facts.files for kind in ("struct", "abstract", "primitive") for node in forms(file, kind))
    found, bound = Finding[], bound_names(facts.files)
    for file in facts.files
        index = FileIndex(binding_positions(file), deferred_names(file), declared_globals(file), bound)
        for block in [file.tree; forms(file, "block")], (assignment, loop) in zip(children_of(block), children_of(block)[2:end])
            kind_name(loop) == "for" || continue
            result = push_finding(file, index, assignment, loop, defined)
            isnothing(result) || push!(found, result)
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.performance, [117], Stage.syntax, findings)

end
