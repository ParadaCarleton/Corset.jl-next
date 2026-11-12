# runic: off
function load(path)
    try
        return read(path, String)
    catch err
        err isa SystemError || rethrow()
        return nothing
    end
end

try
    run_job()
catch err
    @error "job failed"
    rethrow()
end

try
    work()
catch err
    if err isa KeyError
        return nothing
    end
    rethrow()
end
