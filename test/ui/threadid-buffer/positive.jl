using Base.Threads: @threads, threadid

function count_all(xs)
    counts = zeros(Int, nthreads())
    @threads for x in xs
        counts[threadid()] += x
    end
    return sum(counts)
end

scratch[Threads.threadid()] = 0
