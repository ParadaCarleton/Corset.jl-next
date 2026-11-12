"""
Spike S2: render Rust-style message with primary and cause spans taken from TypedSyntax mapping.

Run: `S2_ROOT=file julia --startup-file=no --project=. render.jl`.
Finds slots assigned values of different types (`vague-type` shape) in `Cases` methods.
"""

include(joinpath(@__DIR__, "measure.jl"))

"""Labeled byte span in file."""
struct Label
    file::String
    first_byte::Int
    last_byte::Int
    text::String
end

"""Span of statement `i`: mapped node, widened to whole assignment when node is its right side."""
function statement_label(mappings, file::String, i::Int, text::String)::Union{Label, Nothing}
    length(mappings[i]) == 1 || return nothing
    node = only(mappings[i])
    parent = node.parent
    parent !== nothing && kind(parent) == K"=" && children(parent)[2] === node && (node = parent)
    range = byte_range(node)
    return Label(file, first(range), last(range), text)
end

"""Line number and column of byte offset."""
function line_column(filetext::String, byte::Int)::Tuple{Int, Int}
    line = 1 + count(==(UInt8('\n')), view(codeunits(filetext), 1:(byte - 1)))
    start = something(findprev(==(UInt8('\n')), codeunits(filetext), byte - 1), 0)
    return (line, byte - start)
end

"""Print finding in Rust compiler style: primary span with `^`, causes with `-`."""
function render(io::IO, header::String, primary::Label, causes::Vector{Label}, why::String)::Nothing
    filetext = read(primary.file, String)
    lines = split(filetext, '\n')
    line, column = line_column(filetext, primary.first_byte)
    println(io, header)
    println(io, "  --> ", relpath(primary.file, @__DIR__), ":", line, ":", column)
    width = ndigits(line) + 1
    println(io, " "^width, "|")
    for (label, marker) in sort([[(c, '-') for c in causes]; (primary, '^')]; by = pair -> pair[1].first_byte)
        label_line, label_column = line_column(filetext, label.first_byte)
        length_on_line = min(label.last_byte - label.first_byte + 1, length(lines[label_line]) - label_column + 1)
        println(io, lpad(label_line, width - 1), " | ", lines[label_line])
        println(io, " "^width, "| ", " "^(label_column - 1), string(marker)^length_on_line, " ", label.text)
    end
    println(io, " "^width, "|")
    println(io, " "^width, "= why: ", why)
    return nothing
end

"""Find slots whose assignments have different types; render one message per slot."""
function vague_slots(io::IO, m::Method)::Nothing
    mi = method_instance(m)
    src, _ = code_typed1_tsn(mi)
    file = string(m.file)
    root, _, _ = locate_definition(m, read(file, String))
    mappings, _ = TypedSyntax.map_ssas_to_source(src, mi, root, 0)
    assignments = Dict{Int, Vector{Tuple{Int, Any}}}()
    for (i, stmt) in enumerate(src.code)
        stmt isa Expr && stmt.head === :(=) && stmt.args[1] isa Core.SlotNumber || continue
        push!(get!(assignments, stmt.args[1].id, []), (i, Core.Compiler.widenconst(src.ssavaluetypes[i])))
    end
    for (slot, writes) in assignments
        first_type = writes[1][2]
        other = findfirst(w -> w[2] != first_type, writes)
        other === nothing && continue
        name = src.slotnames[slot]
        cause = statement_label(mappings, file, writes[1][1], "starts as $first_type")
        primary = statement_label(mappings, file, writes[other][1], "becomes $(writes[other][2])")
        primary === nothing || cause === nothing || render(
            io, "performance[vague-type]: `$name` changes type inside loop", primary, [cause],
            "later uses cannot compile for one type; each one dispatches at run time"
        )
    end
    return nothing
end

vague_slots(stdout, only(methods(Cases.inbounds_loop)))
