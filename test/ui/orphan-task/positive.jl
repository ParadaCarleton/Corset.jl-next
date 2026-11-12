# runic: off
function start(jobs)
    for job in jobs
        Threads.@spawn run(job)
    end
    return nothing
end

@async serve()
