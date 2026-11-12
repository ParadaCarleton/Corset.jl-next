function collect_names(people)
    names = []
    for p in people
        push!(names, p.name)
    end
    return names
end

seen = Set()
cache = Dict()
slots = Vector(undef, 4)
