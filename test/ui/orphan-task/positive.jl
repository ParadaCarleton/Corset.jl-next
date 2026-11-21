# runic: off
function start(jobs)
    for job in jobs
        Threads.@spawn run(job)
    end
    return nothing
end

@async serve()

function background()
    @async log_forever()
    return 1
end

function start_ready(jobs)
    for job in jobs
        ready(job) && @async run(job)
    end
    return nothing
end
