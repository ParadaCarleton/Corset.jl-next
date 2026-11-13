# runic: off
ENV["JULIA_DEBUG"] = "all"
delete!(ENV, "PROXY")
withenv("CFLAGS" => "-O2") do
    run(`make`)
end
cd("build")
