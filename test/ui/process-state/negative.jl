# runic: off
level = ENV["LOG_LEVEL"]
home = get(ENV, "HOME", "/root")
known = haskey(ENV, "PATH")
settings = merge!(Dict{String, String}(), ENV)
names = push!(String[], ENV["USER"])
copied = copy(ENV)
env = Dict(ENV)
env["PATH"] = "/opt/bin"
delete!(env, "PATH")
command = addenv(`make`, "CFLAGS" => "-O2")
run(Cmd(`make`; dir = "src"))
directory = pwd()
ENVIRONMENT["A"] = "1"
config.ENV["A"] = "1"
