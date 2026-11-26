"""
Record of crash journal: inference of store `key` started (`finished` false; `label` names method for crash note), or
finished with store `entry` (`nothing` when store keeps none). Start is `alone` when no other inference runs beside it.
Journal lets relaunching process run inference again past native abort that Julia `try` cannot catch (`architecture.md`,
process model).
"""
struct Record
    key::String
    label::String
    finished::Bool
    alone::Bool
    entry::Union{Nothing, Entry}
end

"""Start record of store `key`; `alone` when no other inference runs beside it."""
start_record(key::String, label::String, alone::Bool)::Record = Record(key, label, false, alone, nothing)

"""Finish record of store `key` with store `entry`."""
finish_record(key::String, entry::Union{Nothing, Entry})::Record = Record(key, "", true, true, entry)

"""Journal file of journal `directory`; directory also holds `log_file`."""
journal_file(directory::String)::String = joinpath(directory, "journal")

"""Crash log of journal `directory`: stderr of inference, with Julia abort report of each crash."""
log_file(directory::String)::String = joinpath(directory, "crash.log")

"""
Records of journal file `path`, oldest first, and byte length of whole records. Kill during write can tear last record
(length, then bytes, `record!`); reading drops it, as start of inference that never began.
"""
function whole_records(path::String)::Tuple{Vector{Record}, Int}
    isfile(path) || return Record[], 0
    size = filesize(path)
    return open(path) do io
        found, ending = Record[], 0
        while size - position(io) >= sizeof(Int)
            width = read(io, Int)
            size - position(io) >= width || break
            push!(found, deserialize(IOBuffer(read(io, width)))::Record)
            ending = position(io)
        end
        found, ending
    end
end

"""Records of journal `directory`, oldest first; empty before first run writes any (`whole_records`)."""
records(directory::String)::Vector{Record} = first(whole_records(journal_file(directory)))

"""
Last start record of each key in `records` that no later finish record closes, oldest first. Key can finish in one
analysis and crash in next (`fix` checks again after edit). Crash of one run beside other inferences gives start of each
inference in flight; crash alone gives its start, after starts of inferences it is part of.
"""
function unfinished(records::AbstractVector{Record})::Vector{Record}
    # Positions: equal start records of one key are `===`, so identity cannot tell last one.
    running = Dict{String, Int}()
    for (position, record) in pairs(records)
        if record.finished
            delete!(running, record.key)
        else
            running[record.key] = position
        end
    end
    return records[sort!(collect(values(running)))]
end

"""Keys of inferences that crashed: unfinished start of `records` that ran alone."""
crashed(records::AbstractVector{Record})::Set{String} = Set(record.key for record in unfinished(records) if record.alone)

"""Keys of inferences that ran beside crashed one: unfinished start of `records` beside other inference."""
suspects(records::AbstractVector{Record})::Set{String} = Set(record.key for record in unfinished(records) if !record.alone)

"""Store of entries that finished records of `records` hold."""
finished_store(records::AbstractVector{Record})::Store = Store(record.key => something(record.entry) for record in records if record.finished && !isnothing(record.entry))

"""
Crash journal open for one run: stream that appends records, keys whose inference crashed earlier runs, and keys that
ran beside crash; run infers each suspect alone.
"""
struct Journal
    io::IOStream
    crashed::Set{String}
    suspects::Set{String}
end

"""
Journal of `directory` open for append, with crashed and suspect keys of earlier runs. Open cuts torn last record, so
appended records stay readable. Reads records before open, so read error leaks no stream.
"""
function open_journal(directory::String)::Journal
    path = journal_file(directory)
    found, width = whole_records(path)
    isfile(path) && filesize(path) > width && open(io -> truncate(io, width), path, "r+")
    # Both sets before `open`: throw between them would leave stream open.
    crash, suspect = crashed(found), suspects(found)
    return Journal(open(path, "a"), crash, suspect)
end

"""Name of `method` with file and line, for crash note: `Newer.scaled at Newer.jl:12`."""
method_label(method::Method)::String = "$(method.module).$(method.name) at $(basename(string(method.file))):$(method.line)"

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
