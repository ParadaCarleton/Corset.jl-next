# runic: off
ENV["JULIA_DEBUG"] = "Corset"
Base.ENV["PATH"] *= ":/opt/bin"
setindex!(ENV, "1", "FLAG")
delete!(ENV, "FLAG")
pop!(ENV, "FLAG", nothing)
push!(ENV, "FLAG" => "1")
empty!(ENV)
merge!(ENV, Dict("A" => "1"))
get!(ENV, "HOME", "/root")
get!(() -> "/root", ENV, "HOME")
get!(ENV, "HOME") do
    homedir()
end
withenv("CFLAGS" => "-O2") do
    run(`make`)
end
withenv(build, "CFLAGS" => "-O2")
cd("build")
cd()
cd(build, "src")
cd("src") do
    run(`make`)
end

function configure!(level)
    ENV["LOG_LEVEL"] = level
    return nothing
end
