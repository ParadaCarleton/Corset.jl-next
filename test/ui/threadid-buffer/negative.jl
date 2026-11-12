function count_all(xs)
    return sum(xs)
end

ids = [threadid() for _ in 1:2]
buffers[taskid] = 0
