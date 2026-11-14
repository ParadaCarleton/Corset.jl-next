# Quoted block carries lines of this file, so expansion statements point here.
macro add_two(ex)
    return quote
        $(esc(ex)) + 2
    end
end
