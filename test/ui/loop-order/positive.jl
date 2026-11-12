# runic: off
function fill_grid!(grid)
    for row in axes(grid, 1)
        for col in axes(grid, 2)
            grid[row, col] = row + col
        end
    end
end

for row in 1:m, col in 1:n
    table[row, col] = 0
end
