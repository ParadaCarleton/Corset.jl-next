"""C function name of foreign call target `target`: symbol, string, tuple of name and library, or quoted form of them."""
function target_name(@nospecialize(target::Any))::Symbol
    target isa QuoteNode && return target_name(target.value)
    target isa Expr && target.head === :tuple && return target_name(first(target.args))
    target isa Tuple && return target_name(first(target))
    return Symbol(target)
end

"""Insert into `found` each foreign call of `code`: C function name with its count of C arguments."""
function foreign_calls!(found::Set{Tuple{Symbol, Int}}, @nospecialize(code::Any))::Nothing
    if code isa Expr
        code.head === :foreigncall && push!(found, (target_name(code.args[1]), length(code.args[3]::Core.SimpleVector)))
        foreach(argument -> foreign_calls!(found, argument), code.args)
    elseif code isa Core.CodeInfo
        foreach(statement -> foreign_calls!(found, statement), code.code)
    end
    return nothing
end

"""Foreign calls of every method of `modules`: C function name with its count of C arguments."""
function module_calls(modules::Tuple{Vararg{Module}})::Set{Tuple{Symbol, Int}}
    found = Set{Tuple{Symbol, Int}}()
    Base.visit(Core.methodtable) do method
        method.module in modules && foreign_calls!(found, Base.uncompressed_ast(method))
        return nothing
    end
    return found
end
