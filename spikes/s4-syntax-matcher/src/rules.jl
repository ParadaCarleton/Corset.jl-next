# Five family-A footguns as matcher patterns; ids from docs/design/footguns.toml.
using .S4Matcher

const always = (_b::Bindings, _node::Red) -> true

"""Constructors whose result is mutable, so `fill(ctor(...), n)` shares one object."""
const MUTABLE_CONSTRUCTORS = Set(["zeros", "ones", "similar", "Vector", "Array", "Matrix", "Dict", "Set", "IdDict", "Ref", "copy", "deepcopy", "rand", "randn", "BitVector", "trues", "falses", "collect", "fill", "IOBuffer"])

"""Whether literal text is numeric zero (`0`, `0.0`, `0f0`, `0x0`)."""
is_zero_literal(text::AbstractString)::Bool = (parsed = tryparse(Float64, replace(text, "f" => "e", "_" => "")); !isnothing(parsed) && iszero(parsed)) || text in ("0x0", "0x00")

zero_guard(b::Bindings, ::Red)::Bool = is_zero_literal(node_text(b.src, b[:_z])) && is_number_leaf(b[:_z])
is_number_leaf(r::Red)::Bool = S4Matcher.JS.kind(r) in (S4Matcher.K"Integer", S4Matcher.K"Float", S4Matcher.K"Float32", S4Matcher.K"HexInt")

const INDEX_USE = compile_pattern("_a[_i]")

"""Rules: F10, F21, F35, F36 (two forms), F68."""
function footgun_rules()::Vector{Rule}
    return Rule[
        Rule(10, "approx-zero", ["_x ≈ _z", "_z ≈ _x", "_x ≉ _z", "_z ≉ _x", "isapprox(_x, _z)", "isapprox(_z, _x)"], zero_guard,
            "approximate compare to zero without `atol` is always false"),
        Rule(21, "empty-any-literal", ["[]", "Dict()", "Set()", "IdDict()", "Vector()", "Any[]"], always,
            "empty literal has `Any` element type"),
        Rule(35, "fill-shared-mutable", ["fill(_ctor(_args...), _dims...)", "fill([_xs...], _dims...)"],
            (b, _) -> !haskey(b.singles, :_ctor) || callee_name(b.src, b[:_ctor]) in MUTABLE_CONSTRUCTORS,
            "`fill` shares one mutable object"),
        Rule(36, "one-to-length", ["1:length(_a)", "1:size(_a, _d)", "1:lastindex(_a)"], always,
            "`1:length(A)` assumes 1-based indices"),
        Rule(68, "threadid-buffer", ["_buf[threadid()]", "_buf[Threads.threadid()]", "_buf[Base.Threads.threadid()]"], always,
            "buffer indexed by `threadid()`"),
    ]
end

"""LintApp-shaped F36: `for i in 1:length(a)` whose body indexes `a[i]`."""
function lintapp_shaped_rules()::Vector{Rule}
    return Rule[
        Rule(36, "one-to-length-loop", ["for _i in 1:length(_a)\n_body...\nend", "for _i in 1:size(_a, _d)\n_body...\nend"],
            (b, node) -> contains_match(INDEX_USE, b, node; fixed = [:_a, :_i]),
            "`1:length(A)` loop indexes `A`"),
    ]
end
