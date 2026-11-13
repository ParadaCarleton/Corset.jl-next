# runic: off
"""Attached docstring."""
area(r) = π * r^2

"""
    volume(r)

Attached triple-quoted docstring.
"""
volume(r) = 4π * r^3 / 3

"Documents existing binding."
area

"Trailing comment keeps docstring attached."  # comment
perimeter(s) = 4s

function sign_name(x)
    x > 0 || return "nonpositive"
    "positive"
end

label = let
    "fixed label"
end

choice = if flag
    "yes"
else
    "no"
end

result = begin
    setup()
    :ok
end

function absorb(f)
    try
        f()
    catch
        nothing
    end
end

@testset "literal statements in macro bodies" begin
    1
    @test true
end

struct Point
    "Field docstring."
    x::Float64
end

nothing
