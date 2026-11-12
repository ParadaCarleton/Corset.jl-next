# runic: off
function start(jobs)
    tasks = [Threads.@spawn run(job) for job in jobs]
    foreach(wait, tasks)
end

@sync for job in jobs
    @async run(job)
end

launcher() = @async serve()

function launch()
    @async serve()
end
