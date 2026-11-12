# runic: off
names = String[]
seen = Set{Int}()
cache = Dict{Symbol, Float64}()
anything = Any[]
slots = Vector{Float64}(undef, 4)
