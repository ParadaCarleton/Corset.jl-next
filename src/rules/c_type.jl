"""
`c-type` (F81): C type alias outside C calls.

## Description
Reports C type aliases such as `Cint`, `Clong` and `Csize_t` outside `ccall`, `@ccall`, `cglobal`, `@cfunction`, `Ptr{}` and `Ref{}`.

## Rationale
Alias hides Julia type from reader. `Clong`, `Culong` and `Cwchar_t` also change width by platform, so code behaves differently on Windows.

## Example
```julia
count::Cint = 0
```

## Alternative
```julia
count::Int32 = 0
```

## Limitations
Rule reads names as written. Local variable named like alias gives false finding.
"""
module CType

using ...Facts

const NAME = Symbol("c-type")
"""C type alias and Julia type it names on 64-bit Linux, for message."""
const C_TYPES = Dict(
    "Cchar" => "Int8", "Cshort" => "Int16", "Cint" => "Int32", "Clong" => "Int64", "Clonglong" => "Int64",
    "Cuchar" => "UInt8", "Cushort" => "UInt16", "Cuint" => "UInt32", "Culong" => "UInt64", "Culonglong" => "UInt64",
    "Csize_t" => "UInt", "Cssize_t" => "Int", "Cfloat" => "Float32", "Cdouble" => "Float64", "Cwchar_t" => "Int32",
)
"""Calls and macros whose arguments describe C interface."""
const C_CONTEXTS = Set(["ccall", "cglobal", "@cfunction", "@ccall"])

"""Whether `node` sits inside C call, C callback, or `Ptr` type."""
function in_c_context(node)::Bool
    return any(ancestors(node)) do ancestor
        call_head(ancestor) in C_CONTEXTS || (kind_name(ancestor) == "macrocall" && leaf_value(children_of(ancestor)[1]) in C_CONTEXTS) ||
            (kind_name(ancestor) == "curly" && identifier_name(children_of(ancestor)[1]) in ("Ptr", "Ref"))
    end
end

"""Findings for C type aliases used outside C interface code."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, node in nodes_named(file, "Identifier")
        name = identifier_name(node)
        haskey(C_TYPES, name) && !in_c_context(node) || continue
        push!(
            found, finding(
                NAME, file, node; kind = :c_alias, confidence = Confidence.definite,
                message = "C type `$name` outside C call", label = "names `$(C_TYPES[name])` on this platform",
                why = "reader must know C ABI to see Julia type; width can change by platform",
                fix = manual_fix("use Julia type (`$(C_TYPES[name])`), or keep `$name` only in `ccall` signatures"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [81], Stage.syntax, run)

end
