# runic: off
function fill_grid!(grid)
    for col in axes(grid, 2)
        for row in axes(grid, 1)
            grid[row, col] = row + col
        end
    end
end

for col in 1:n, row in 1:m
    table[row, col] = 0
end

for row in 1:m
    total += sums[row, 1]
end
