# runic: off
task = @async fetch_data(url)
worker = Task(() -> work())
Threads.@threads :static for index in 1:4
    work(index)
end
