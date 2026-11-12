# Five family-A footguns as matcher patterns; ids from docs/design/footguns.toml.
using .S4Matcher
using .S4Matcher: JS, @K_str

const always = (_b::Bindings, _node::Red, _ancestors::Vector{Red}) -> true

"""Constructors whose result is mutable, so `fill(ctor(...), n)` shares one object."""
const MUTABLE_CONSTRUCTORS = Set(["zeros", "ones", "similar", "Vector", "Array", "Matrix", "Dict", "Set", "IdDict", "Ref", "copy", "deepcopy", "rand", "randn", "BitVector", "trues", "falses", "collect", "fill", "IOBuffer"])

"""Whether literal text is numeric zero (`0`, `0.0`, `0f0`, `0x0`)."""
is_zero_literal(text::AbstractString)::Bool = (parsed = tryparse(Float64, replace(text, "f" => "e", "_" => "")); !isnothing(parsed) && iszero(parsed)) || text in ("0x0", "0x00")

is_number_leaf(r::Red)::Bool = JS.kind(r) in (K"Integer", K"Float", K"Float32", K"HexInt")
zero_guard(b::Bindings, ::Red, ::Vector{Red})::Bool = is_number_leaf(b[:_z]) && is_zero_literal(node_text(b.src, b[:_z]))

const INDEX_USE = compile_pattern("_a[_i]")
const ONE_BASED_GUARDS = [compile_pattern("require_one_based_indexing(_pre..., _a, _post...)"), compile_pattern("Base.require_one_based_indexing(_pre..., _a, _post...)")]

"""Whether enclosing function calls `require_one_based_indexing` on bound `_a`."""
function one_based_checked(b::Bindings, ancestors::Vector{Red})::Bool
    i = findlast(r -> JS.kind(r) == K"function" || (JS.kind(r) == K"=" && JS.has_flags(r.green, JS.SHORT_FORM_FUNCTION_FLAG)), ancestors)
    isnothing(i) && return false
    return any(p -> contains_match(p, b, ancestors[i]; fixed = [:_a]), ONE_BASED_GUARDS)
end

one_to_length_guard(b::Bindings, ::Red, ancestors::Vector{Red})::Bool = !one_based_checked(b, ancestors)

"""Rules: F10, F21, F35, F36, F68."""
function footgun_rules()::Vector{Rule}
    return Rule[
        Rule(
            10, "approx-zero", ["_x ≈ _z", "_z ≈ _x", "_x ≉ _z", "_z ≉ _x", "isapprox(_x, _z)", "isapprox(_z, _x)"], zero_guard,
            "approximate compare to zero without `atol` is always false"
        ),
        Rule(
            21, "empty-any-literal", ["[]", "Dict()", "Set()", "IdDict()", "Vector()", "Any[]"], always,
            "empty literal has `Any` element type"
        ),
        Rule(
            35, "fill-shared-mutable", ["fill(_ctor(_args...), _dims...)", "fill([_xs...], _dims...)"],
            (b, _, _) -> !haskey(b.singles, :_ctor) || callee_name(b.src, b[:_ctor]) in MUTABLE_CONSTRUCTORS,
            "`fill` shares one mutable object"
        ),
        Rule(
            36, "one-to-length", ["1:length(_a)", "1:size(_a, _d)", "1:lastindex(_a)"], one_to_length_guard,
            "`1:length(A)` assumes 1-based indices"
        ),
        Rule(
            68, "threadid-buffer", ["_buf[threadid()]", "_buf[Threads.threadid()]", "_buf[Base.Threads.threadid()]"], always,
            "buffer indexed by `threadid()`"
        ),
    ]
end

"""LintApp-shaped F36: `for i in 1:length(a)` whose body indexes `a[i]`."""
function lintapp_shaped_rules()::Vector{Rule}
    return Rule[
        Rule(
            36, "one-to-length-loop", ["for _i in 1:length(_a)\n_body...\nend", "for _i in 1:size(_a, _d)\n_body...\nend", "(_body for _i in 1:length(_a))", "(_body for _i in 1:size(_a, _d))"],
            (b, node, ancestors) -> contains_match(INDEX_USE, b, node; fixed = [:_a, :_i]) && !one_based_checked(b, ancestors),
            "`1:length(A)` loop indexes `A`"
        ),
    ]
end
