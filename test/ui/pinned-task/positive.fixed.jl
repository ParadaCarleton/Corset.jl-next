# runic: off
task = Threads.@spawn fetch_data(url)
Threads.@spawn serve()
handle = Threads.@spawn begin
    work()
end

function start(f)
    task = Task(f)
    schedule(task)
    return task
end

schedule(Task(() -> work()))
job = @task compute()

Threads.@threads :static for i in 1:10
    work(i)
end

@threads :static for item in items
    process(item)
end

function other_name(f)
    task = Task(f)
    other.sticky = false
    return task
end

function opt_out_too_early(f)
    task.sticky = false
    task = Task(f)
    return task
end

function opt_out_in_branch(f, flag)
    task = Task(f)
    if flag
        task.sticky = false
    end
    return task
end

function opt_out_reverted(f)
    task = Task(f)
    task.sticky = true
    return task
end
