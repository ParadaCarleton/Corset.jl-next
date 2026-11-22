"""
Record of crash journal: inference of store `key` started (`finished` false; `label` names method for crash note), or
finished with store `entry` (`nothing` when store keeps none). Journal lets relaunching process run inference again
past native abort that Julia `try` cannot catch (`architecture.md`, process model).
"""
struct Record
    key::String
    label::String
    finished::Bool
    entry::Union{Nothing, Entry}
end

"""Journal file of journal `directory`; directory also holds `log_file`."""
journal_file(directory::String)::String = joinpath(directory, "journal")

"""Crash log of journal `directory`: stderr of inference, with Julia abort report of each crash."""
log_file(directory::String)::String = joinpath(directory, "crash.log")

"""
Records of journal `directory`, oldest first; empty before first run writes any. Kill during write can tear last
record (length, then bytes, `record!`); records drops it, as start of inference that never began.
"""
function records(directory::String)::Vector{Record}
    path = journal_file(directory)
    isfile(path) || return Record[]
    size = filesize(path)
    return open(path) do io
        found = Record[]
        while size - position(io) >= sizeof(Int)
            width = read(io, Int)
            size - position(io) >= width || break
            push!(found, deserialize(IOBuffer(read(io, width)))::Record)
        end
        found
    end
end

"""
Keys of inferences that crashed: started record of `records` that no later finished record of same key closes. Key
can finish in one analysis and crash in next (`fix` checks again after edit).
"""
function crashed(records::Vector{Record})::Set{String}
    running = Set{String}()
    for record in records
        if record.finished
            delete!(running, record.key)
        else
            push!(running, record.key)
        end
    end
    return running
end

"""Store of entries that finished records of `records` hold."""
finished_store(records::Vector{Record})::Store = Store(record.key => something(record.entry) for record in records if record.finished && !isnothing(record.entry))

"""Crash journal open for one run: stream that appends records, and keys whose inference crashed earlier runs."""
struct Journal
    io::IOStream
    crashed::Set{String}
end

"""Journal of `directory` open for append, with crashed keys of earlier runs; reads records before open, so read error leaks no stream."""
function open_journal(directory::String)::Journal
    keys = crashed(records(directory))
    return Journal(open(journal_file(directory), "a"), keys)
end

"""Name of `method` with file and line, for crash note: `Newer.scaled at Newer.jl:12`."""
method_label(method::Method)::String = "$(method.module).$(method.name) at $(basename(string(method.file))):$(method.line)"

"""Last record of `records` when it starts inference no record finishes: crash of run that wrote it; else `nothing`."""
last_crash(records::Vector{Record})::Union{Nothing, Record} = isempty(records) || last(records).finished ? nothing : last(records)

"""Write `record` to `journal` and flush it, so process that aborts next leaves it on disk."""
function record!(journal::Journal, record::Record)::Nothing
    buffer = IOBuffer()
    serialize(buffer, record)
    bytes = take!(buffer)
    # One write of length and bytes, so torn record is short and `records` can tell.
    write(journal.io, [reinterpret(UInt8, [length(bytes)]); bytes])
    flush(journal.io)
    return nothing
end
