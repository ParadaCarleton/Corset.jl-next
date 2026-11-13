# runic: off
task = Threads.@spawn fetch_data(url)

Threads.@threads for i in 1:10
    work(i)
end

@threads :dynamic for item in items
    process(item)
end

@threads :greedy for item in items
    process(item)
end

function unpinned(f)
    task = Task(f)
    task.sticky = false
    schedule(task)
    return task
end

function unpinned_macro()
    job = @task compute()
    job.sticky = false
    return schedule(job)
end

pinned = Task(work); pinned.sticky = false

tasks = Task[]
slots = Vector{Task}(undef, 4)
running = current_task()
Mine.@async work()
@async_logged work()

# Opt-out still counts when assignment sits inside `return`.
function unpinned_result()
    worker = Task(work)
    return worker.sticky = false
end
