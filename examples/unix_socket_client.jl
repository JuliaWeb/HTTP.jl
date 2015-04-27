using Requests
using HttpCommon
using HttpParser

function process_response(stream)
    r = Response()
    rp = Requests.ResponseParser(r,stream)
    while isopen(stream)
        data = readavailable(stream)
        if length(data) > 0
            http_parser_execute(rp.parser, rp.settings, data)
        end
    end
    http_parser_execute(rp.parser,rp.settings,"") #EOF
    r
end

clientside = connect("/tmp/julia.socket")
req = Requests.default_request("GET", "/", "/tmp/julia.socket", "")
dump(req)
write(clientside, Requests.render(req))
dump(process_response(clientside))
