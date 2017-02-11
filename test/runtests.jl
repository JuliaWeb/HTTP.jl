using HTTP, Base.Test

# TODO
  # docs:
    # manual page
  # server.jl
    # docs
    # tests
  # proxy stuff, multi-part files, digest auth

@testset "HTTP" begin
    include("../src/precompile.jl") # to make codecov happy
    _precompile_()

    include("utils.jl");
    include("fifobuffer.jl");
    include("sniff.jl");
    include("uri.jl");
    include("cookies.jl");
    include("parser.jl");
    include("types.jl");
    include("client.jl");
    include("server.jl")
end;

# server_task = @async HTTP.serve()
#
# client = connect("127.0.0.1", 8081)
# write(client, "OPTIONS * HTTP/1.1\r\n\r\n")
# sleep(1)
# resp = String(readavailable(client))

# reject invalid HTTP versions

# test a variety of invalid requests (see http_parser error codes?)
  # invalid METHOD (501 not implemented status)
  # URI too long (414 status)
  # invalid HTTP versions
  # whitespace where there shouldn't be
  # reject message w/ space between header field & colon (400) # https://tools.ietf.org/html/rfc7230#section-3.2.4
  # non-encoded target resource w/ spaces (return 400)
  # duplicate headers
  # no space between header field name and colon
  # reject obs-fold multi-line header field values (400 bad request)


# limit on overall header size # https://tools.ietf.org/html/rfc7230#section-3.2.5

# no response body
 # HEAD requests
 # 1xx and 2xx responses
 # CONNECT requests
 # 204, 304

# no transfer-encoding header in response to:
 # 1xx or 204 response statuses
 # CONNECT request

# https://tools.ietf.org/html/rfc7230#section-3.3.1
# unsupported transfer-endcoding => 501 not implemented

# bad request 400 on multiple Content-Length headers

# timeout and close connection when bytes received don't match Content-Length from client

# https://tools.ietf.org/html/rfc7230#section-3.5
# ignore preceeding CRLF to request-line

# https://tools.ietf.org/html/rfc7230#section-4.1.1
# ignore unsupported chunk-extensions

# https://tools.ietf.org/html/rfc7230#section-4.1.2
# chunk trailer headers are handled appropriately

# https://tools.ietf.org/html/rfc7230#section-4.2
# transfer-encodings supported: compress, deflate, gzip, x-gzip

# https://tools.ietf.org/html/rfc7230#section-5.4
# 400 for no Host or multiple Host headers

# https://tools.ietf.org/html/rfc7230#section-6.1
# test keep-alive support

# https://tools.ietf.org/html/rfc7230#section-6.5
# test an inactive client (i.e. sent keep-alive, but didn't send anything else)




# https://tools.ietf.org/html/rfc7230#section-3
# The normal procedure for parsing an HTTP message is to read the
#   start-line into a structure, read each header field into a hash table
#   by field name until the empty line, and then use the parsed data to
#   determine if a message body is expected.  If a message body has been
#   indicated, then it is read as a stream until an amount of octets
#   equal to the message body length is read or the connection is closed.

# A sender MUST NOT send whitespace between the start-line and the
#    first header field.  A recipient that receives whitespace between the
#    start-line and the first header field MUST either reject the message
#    as invalid or consume each whitespace-preceded line without further
#    processing of it (i.e., ignore the entire line, along with any
#    subsequent lines preceded by whitespace, until a properly formed
#    header field is received or the header section is terminated).

# reject a received request: https://tools.ietf.org/html/rfc7230#section-3.1
# restrict uri length to 8000 by default: https://tools.ietf.org/html/rfc7230#section-3.1.1

# https://tools.ietf.org/html/rfc7230#section-3.2.2
# handle response w/ multiple "Set-Cookie" header fields

# https://tools.ietf.org/html/rfc7230#section-3.3
# never a repsonse body in HEAD/CONNECT requests
# 1xx, 204, 304 don't include bodies