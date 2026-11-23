"""
`operator-consistency` (F22, F104): equality, `hash` and `isless` break Base contract; method on derived operator.

## Description
Reports package type whose equality, `hash` and `isless` methods break contract Base documents for `isequal`:
- `==` or `isequal` method, and `hash` does not cover type beyond Base default.
- `hash` method reads field that equality does not compare.
- `==` without `isequal` on type whose compared fields hold floats; `possible` when field type only admits floats.
- `hash` method over fields without equality, on type `===` compares by identity (`possible`: identity can be intended).
- 1-argument `hash` method, often from default for `h`.
- `isless` method compares other fields than equality (`possible`: sort key can be intended).
Also reports method on `!=`, `>` or `>=`, operators Base derives from `==`, `<` and `<=`.

## Rationale
`Dict` and `Set` find keys by `hash`, then `isequal`, so `isequal(x, y)` must imply `hash(x) == hash(y)`.
`isequal` falls back to `==`, and Base default `hash` follows `===`, so own `==` needs own `hash`.
`isequal` differs from `==` on floats: `0.0 == -0.0` holds, `isequal(0.0, -0.0)` does not, and their hashes differ.
Base `hash(x)` calls `hash(x, HASH_SEED)`; 1-argument method uses another seed.
Exactly one of `isequal(x, y)`, `isless(x, y)` and `isless(y, x)` must hold.
Own method on derived operator can drift from operator it derives from: `a != b` and `!(a == b)` then differ.

## Example
```julia
struct Span
    start::Float64
    stop::Float64
end
Base.:(==)(a::Span, b::Span) = a.start == b.start && a.stop == b.stop
Base.:(!=)(a::Span, b::Span) = !(a == b)
```

## Alternative
```julia
struct Span
    start::Float64
    stop::Float64
end
Base.:(==)(a::Span, b::Span) = a.start == b.start && a.stop == b.stop
Base.isequal(a::Span, b::Span) = isequal(a.start, b.start) && isequal(a.stop, b.stop)
Base.hash(span::Span, h::UInt) = hash(span.stop, hash(span.start, hash(Span, h)))
```

## Limitations
Field checks read `x.field` and `getfield(x, :field)` only; method that passes whole argument to call skips them.
Float check reads declared field types and their parameters; it does not follow fields of nested structs.
`isless` check needs own equality whose fields are known.
Method counts when its first package type argument is struct or abstract type; unions are skipped.
"""
module OperatorConsistency

using ...Facts

const NAME = Symbol("operator-consistency")

"""Operators Base derives from other operator: derived operator, its source, and Base definition."""
const DERIVED = [(operator = !=, source = "==", definition = "!(a == b)"), (operator = >, source = "<", definition = "b < a"), (operator = >=, source = "<=", definition = "b <= a")]

"""Functions whose package methods this rule reads per compared type."""
const CONTRACT = (==, isequal, hash, isless)

"""Package method sites on `CONTRACT` functions for one type, by function name."""
const Sites = Dict{Symbol, Vector{MethodSite}}

"""Base fallbacks: `x == y` as `x === y`, `isequal(x, y)` as `x == y`, `hash(x, h)` from `objectid`."""
fallbacks()::NTuple{3, Method} = (which(==, Tuple{Any, Any}), which(isequal, Tuple{Any, Any}), which(hash, Tuple{Any, UInt}))

"""Function type of `method`: `typeof(==)` for method of `==`."""
function_type(method::Method)::Any = tuple_parameters(method.sig)[1]

"""First argument type of `method` that names type package `modules` define, with signature type variables; else `nothing`."""
function compared_type(method::Method, modules::AbstractSet{Module})::Union{Nothing, Type}
    for position in 1:(method.nargs - 1)
        type = argument_type(method, position)
        body = isnothing(type) ? nothing : Base.unwrap_unionall(type)
        body isa DataType && parentmodule(body) in modules && return type
    end
    return nothing
end

"""Method of `callee` other than Base `fallbacks` that covers every call with `arguments`; `nothing` when none does."""
function covering(callee::Function, arguments::Tuple, skipped::NTuple{3, Method})::Union{Nothing, Method}
    signature = Tuple{typeof(callee), arguments...}
    candidates = collect(methods(callee, Tuple{arguments...}))
    index = findfirst(method -> !(method in skipped) && signature <: method.sig, candidates)
    return isnothing(index) ? nothing : candidates[index]
end

"""Whether argument `position` of `method` has type named `name`."""
names_type(method::Method, position::Integer, name::Core.TypeName)::Bool = (argument = argument_type(method, position); !isnothing(argument) && (body = Base.unwrap_unionall(argument); body isa DataType && body.name === name))

"""
Method `isequal` reaches for two values of `type`: `isequal`, else `==`, other than Base fallbacks; `nothing` when values
compare by `===`. Diagonal package method (`a::Point{T}, b::Point{T}`) covers no mixed pair, so it counts from `sites`.
"""
function equality(type::Type, sites::Sites, skipped::NTuple{3, Method})::Union{Nothing, Method}
    name = Base.unwrap_unionall(type).name
    for compare in (isequal, ==)
        own = covering(compare, (type, type), skipped)
        isnothing(own) || return own
        candidates = get(sites, nameof(compare), MethodSite[])
        index = findfirst(site -> names_type(site.method, 1, name) && names_type(site.method, 2, name), candidates)
        isnothing(index) || return candidates[index].method
    end
    return nothing
end

"""Fields of struct `type`; empty for abstract type."""
function struct_fields(type::Type)::Set{Symbol}
    body = Base.unwrap_unionall(type)
    fields = Set{Symbol}()
    isstructtype(body) || return fields
    # Typed loop: `Set(fieldnames(body))` calls `Set(::Any)`, which packages that target loads invalidate.
    for name in fieldnames(body)
        push!(fields, name::Symbol)
    end
    return fields
end

"""Whether `slot` appears anywhere in `expression`."""
mentions(expression::Any, slot::Core.SlotNumber)::Bool =
    expression == slot || (expression isa Expr && any(argument -> mentions(argument, slot), expression.args))

"""
Value side of lowered `statement`: right side of assignment, else statement itself. Lowering copies reassigned
argument to new slot, so assignment never targets argument slot, and reads after rebind make fields unknown.
"""
value_side(statement::Any)::Any = statement isa Expr && statement.head === :(=) ? statement.args[2] : statement

"""
Fields `method` reads from arguments of `type`, by `x.field` or `getfield(x, :field)`; `nothing` when method uses such
argument any other way (passes it whole, returns it), so fields it reads stay unknown.
"""
function read_fields(method::Method, type::Type)::Union{Nothing, Set{Symbol}}
    name = Base.unwrap_unionall(type).name
    slots = [Core.SlotNumber(position + 1) for position in 1:(method.nargs - 1) if names_type(method, position, name)]
    code = Base.uncompressed_ast(method).code
    fields = Set{Symbol}()
    for statement in code, slot in slots
        mentions(statement, slot) || continue
        call = value_side(statement)
        call isa Expr || return nothing
        read = call.head === :call && length(call.args) == 3 && call.args[2] == slot &&
            call.args[3] isa QuoteNode && lowered_value(code, call.args[1]) isa Union{typeof(getproperty), typeof(getfield)}
        read || return nothing
        push!(fields, call.args[3].value)
    end
    return fields
end

"""
Whether values of declared field `type` can hold floats: `definite` when type or one of its parameters is float type,
`possible` when they only admit floats (`Any`, `Real`, type variable), else `nothing`.
"""
function float_confidence(type::Any)::Union{Nothing, Confidence.T}
    type isa TypeVar && return isnothing(float_confidence(type.ub)) ? nothing : Confidence.possible
    (type isa Type && type !== Union{}) || return nothing
    type <: AbstractFloat && return Confidence.definite
    typeintersect(type, AbstractFloat) === Union{} || return Confidence.possible
    body = Base.unwrap_unionall(type)
    body isa DataType || return nothing
    found = [float_confidence(parameter) for parameter in body.parameters]
    Confidence.definite in found && return Confidence.definite
    return Confidence.possible in found ? Confidence.possible : nothing
end

"""Float confidence over `fields` of struct `type`: `definite` when one field holds floats, `possible` when one may."""
function fields_float(type::Type, fields::AbstractSet{Symbol})::Union{Nothing, Confidence.T}
    body = Base.unwrap_unionall(type)
    found = [float_confidence(fieldtype(body, field)) for field in intersect(fields, struct_fields(type))]
    Confidence.definite in found && return Confidence.definite
    return Confidence.possible in found ? Confidence.possible : nothing
end

"""Whether `===` compares values of `type` by identity: mutable struct, or struct with mutable field other than `String`."""
function identity_compared(type::Type)::Bool
    body = Base.unwrap_unionall(type)
    isstructtype(body) || return false
    ismutabletype(body) && return true
    return any(field -> field isa DataType && ismutabletype(field) && field !== String, fieldtypes(body))
end

"""Fields `method` compares as text: `` `a`, `b` ``."""
field_list(fields::AbstractSet{Symbol})::String = join(("`$field`" for field in sort!(collect(fields))), ", ")

"""Site of `method` among package `sites`; `nothing` for method package code does not define."""
site_of(method::Method, sites::AbstractVector{MethodSite})::Union{Nothing, MethodSite} = (index = findfirst(site -> site.method === method, sites); isnothing(index) ? nothing : sites[index])

"""Finding for method `site` on derived operator `derived`."""
function derived_finding(site::MethodSite, derived::NamedTuple)::Finding
    operator = nameof(derived.operator)
    return Finding(
        NAME, :derived_operator, Confidence.definite, "method on `$operator`, which Base derives from `$(derived.source)`",
        Label(name_span(site), "can disagree with `$(derived.source)`"), Label[],
        "Base defines `a $operator b` as `$(derived.definition)`; own method can drift from it",
        manual_fix("delete method; define `$(derived.source)` only"),
    )
end

"""Finding for equality `sites` on package `type` that `hash` does not cover; fix adds `isequal` when compared fields hold floats."""
function unhashed_finding(type::Type, sites::AbstractVector{MethodSite}, floats::Bool)::Finding
    name = nameof(Base.unwrap_unionall(type))
    fix = floats ? "define `Base.isequal` and `Base.hash(x::$name, h::UInt)` that apply `isequal` and `hash` to fields `==` compares" :
        "define `Base.hash(x::$name, h::UInt)` over fields equality compares"
    return Finding(
        NAME, :eq_without_hash, Confidence.definite, "`$(first(sites).method.name)` defined for `$name` without `hash`",
        Label(name_span(first(sites)), "equality without matching `hash`"), [Label(name_span(site), "also defines equality") for site in Iterators.drop(sites, 1)],
        "`Dict` and `Set` need `isequal(x, y)` to imply equal hashes; Base default `hash` follows `===`, so equal values miss",
        manual_fix(fix),
    )
end

"""Finding for `==` at `site` on package `type` whose compared fields hold floats, with `hash` and without `isequal`."""
function float_finding(type::Type, site::MethodSite, confidence::Confidence.T)::Finding
    name = nameof(Base.unwrap_unionall(type))
    return Finding(
        NAME, :float_without_isequal, confidence, "`==` defined for `$name` without `isequal`; compared fields hold floats",
        Label(name_span(site), "`isequal` falls back to this `==`"), Label[],
        "`0.0 == -0.0` holds, but their hashes differ; `isequal` must tell them apart, as it does for `Float64`",
        manual_fix("define `Base.isequal(a::$name, b::$name)` that applies `isequal` to fields `==` compares"),
    )
end

"""Finding for `hash` at `site` that reads `extra` fields equality at `compared` ignores."""
function extra_field_finding(type::Type, site::MethodSite, extra::AbstractSet{Symbol}, compared::MethodSite)::Finding
    name = nameof(Base.unwrap_unionall(type))
    return Finding(
        NAME, :hash_extra_field, Confidence.definite, "`hash` for `$name` reads $(field_list(extra)), which equality ignores",
        Label(name_span(site), "hashes more than equality compares"), [Label(name_span(compared), "equality")],
        "values `isequal` calls equal can differ in $(field_list(extra)), so their hashes differ and `Dict` keys miss",
        manual_fix("hash only fields equality compares"),
    )
end

"""Finding for `hash` at `site` on package `type` that `===` compares by identity, without own equality."""
function identity_finding(type::Type, site::MethodSite)::Finding
    name = nameof(Base.unwrap_unionall(type))
    return Finding(
        NAME, :hash_without_eq, Confidence.possible, "`hash` defined for `$name` without `==`",
        Label(name_span(site), "`isequal` still compares by `===`"), Label[],
        "`Dict` and `Set` compare `$name` keys by identity; values with equal fields stay separate keys",
        manual_fix("define `==` over fields `hash` reads; delete `hash` when identity is intended"),
    )
end

"""Finding for 1-argument `hash` method at `site` on package `type`."""
function seed_finding(type::Type, site::MethodSite)::Finding
    name = nameof(Base.unwrap_unionall(type))
    return Finding(
        NAME, :hash_one_argument, Confidence.definite, "1-argument `hash` method for `$name`",
        Label(name_span(site), "replaces Base seed"), Label[],
        "Base `hash(x)` calls `hash(x, HASH_SEED)`; this method uses other seed, so `isequal` values of other types can hash differently",
        manual_fix("define 2-argument form only; delete default of `h`"),
    )
end

"""Finding for `isless` at `site` that compares `ordered` fields where equality at `compared` compares `equal` fields."""
function order_finding(type::Type, site::MethodSite, ordered::AbstractSet{Symbol}, compared::MethodSite, equal::AbstractSet{Symbol})::Finding
    name = nameof(Base.unwrap_unionall(type))
    return Finding(
        NAME, :isless_mismatch, Confidence.possible, "`isless` for `$name` compares $(field_list(ordered)); equality compares $(field_list(equal))",
        Label(name_span(site), "orders by other fields than equality"), [Label(name_span(compared), "equality")],
        "exactly one of `isequal(x, y)`, `isless(x, y)` and `isless(y, x)` must hold for every `x` and `y`",
        manual_fix("compare fields equality compares; for sort key, sort with `by` instead"),
    )
end

"""Findings for package type `type` from its methods `sites` on `CONTRACT` functions, by function."""
function contract_findings(type::Type, sites::Sites, all_sites::AbstractVector{MethodSite}, skipped::NTuple{3, Method})::Vector{Finding}
    found = Finding[]
    for site in get(sites, :hash, MethodSite[])
        site.method.nargs == 2 && push!(found, seed_finding(type, site))
    end
    equals = [get(sites, :(==), MethodSite[]); get(sites, :isequal, MethodSite[])]
    compared = equality(type, sites, skipped)
    compared_site = isnothing(compared) ? nothing : site_of(compared, all_sites)
    equal = isnothing(compared_site) ? nothing : read_fields(compared, type)
    # `==` without own `isequal` is what `isequal` reaches; fields it compares decide float check.
    by_eq = !isnothing(compared_site) && compared.name === :(==)
    floats = by_eq ? fields_float(type, something(equal, struct_fields(type))) : nothing
    hashed = covering(hash, (type, UInt), skipped)
    hash_site = isnothing(hashed) ? nothing : site_of(hashed, all_sites)
    hashed_fields = isnothing(hash_site) ? nothing : read_fields(hashed, type)
    if isnothing(hashed)
        isempty(equals) || push!(found, unhashed_finding(type, equals, !isnothing(floats)))
    elseif isnothing(compared)
        # `hash` over fields asks for value equality; `hash(objectid(x), h)` keeps identity on purpose.
        valued = !isnothing(hashed_fields) && !isempty(hashed_fields)
        valued && identity_compared(type) && push!(found, identity_finding(type, hash_site))
    elseif !isnothing(compared_site)
        isnothing(floats) || push!(found, float_finding(type, compared_site, floats))
        extra = isnothing(hashed_fields) || isnothing(equal) ? Set{Symbol}() : setdiff(hashed_fields, equal)
        isempty(extra) || push!(found, extra_field_finding(type, hash_site, extra, compared_site))
    end
    isnothing(equal) && return found
    for site in get(sites, :isless, MethodSite[])
        ordered = read_fields(site.method, type)
        isnothing(ordered) || ordered == equal || push!(found, order_finding(type, site, ordered, compared_site, equal))
    end
    return found
end

"""Findings for package methods on derived operators, and for package types whose equality, `hash` and `isless` disagree."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    modules = Set(package.modules)
    skipped = fallbacks()
    found = Finding[]
    types = Dict{Core.TypeName, Tuple{Type, Sites}}()
    for site in package.methods
        type = function_type(site.method)
        derived = findfirst(entry -> type === typeof(entry.operator), DERIVED)
        isnothing(derived) || push!(found, derived_finding(site, DERIVED[derived]))
        contract = findfirst(callee -> type === typeof(callee), CONTRACT)
        isnothing(contract) && continue
        compared = compared_type(site.method, modules)
        isnothing(compared) && continue
        entry = get!(types, Base.unwrap_unionall(compared).name, (compared, Sites()))
        push!(get!(last(entry), nameof(CONTRACT[contract]), MethodSite[]), site)
    end
    for (type, sites) in values(types)
        append!(found, contract_findings(type, sites, package.methods, skipped))
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [22, 104], Stage.package, findings)

end
