grid = [zeros(3) for _ in 1:4]
table = [Dict{String, Int}() for _ in 1:m, _ in 1:n]
rows = [[0, 0] for _ in 1:n]
nested = fill(Int[], (2, 2))
