using HTTP
using Reseau

# The test runner supplies the peer and runtime inputs from outside this executable.
function @main(args::Vector{String})::Cint
    length(args) == 2 || return 2
    method, address = args
    method in ("GET", "POST") || return 2
    payload = method == "GET" ? UInt8[] : Vector{UInt8}(codeunits("writer-native-test"))
    try
        response = HTTP.request(method, "http://" * address * "/upload";
            body = payload, protocol = :h1, proxy = HTTP.ProxyConfig(),
            retry = false, redirect = false, cookies = false)
        response.status == 200 || return 3
        String(response.body::Vector{UInt8}) == "ok" || return 4
        return 0
    finally
        HTTP.close_idle_connections!()
        Reseau.IOPoll.shutdown!()
    end
end

Base.Experimental.entrypoint(main, (Vector{String},))
