function load(path)
    try
        return read(path, String)
    catch
    end
end

try
    run_job()
catch err
    @warn "job failed" err
end
