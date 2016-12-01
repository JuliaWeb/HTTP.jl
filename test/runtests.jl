using HTTP, Base.Test

include("uri.jl")
include("parser.jl")

server_task = @async HTTP.serve()

client = connect("127.0.0.1:8081")
write(client, "OPTIONS * HTTP/1.1\r\n\r\n")
sleep(1)
resp = String(readavailable(client))

# reject invalid HTTP versions

# test a variety of invalid requests (see http_parser error codes?)
  # invalid METHOD (501 not implemented status)
  # URI too long (414 status)
  # invalid HTTP versions
  # whitespace where there shouldn't be
  # non-encoded target resource w/ spaces (return 400)
  # duplicate headers
  # no space between header field name and colon
  # reject obs-fold multi-line header field values (400 bad request)


# limit on overall header size? body size?

# no response body
 # HEAD requests
 # 1xx and 2xx responses
 # CONNECT requests
 # 204, 304

# no transfer-encoding header in response to:
 # 1xx or 204 response statuses
 # CONNECT request

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






#
