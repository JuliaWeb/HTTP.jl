include("trim_workload_common.jl")

function run_http_trim_sse()::Nothing
    stream = HT.SSEStream()
    write(stream, HT.SSEEvent("hello\nworld"; event = "greeting", id = "1", retry = 5))
    close(stream)
    expected = "event: greeting\nid: 1\nretry: 5\ndata: hello\ndata: world\n\n"
    trim_body_string(stream) == expected || error("unexpected SSE event serialization")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_sse()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
