using Sockets, HTTP
h = HTTP.Handlers.Handler(x->HTTP.Response(200))
host = "127.0.0.1"
port = 8081
inet = HTTP.Servers.getinet(host, port)
tcpserver = Sockets.listen(inet)
tcpisvalid = x->true
server = HTTP.Servers.Server2(nothing, tcpserver, string(host), string(port))
connectioncounter = Ref(0)
reuse_limit = 1
readtimeout = 0
verbose = false
@code_warntype HTTP.Servers.listenloop(h, server, tcpisvalid, connectioncounter, reuse_limit, readtimeout, verbose)

conn = HTTP.Connection(server.hostname, server.hostport, 0, 0, true, Sockets.TCPSocket())
@code_warntype HTTP.Servers.handle(h, conn, reuse_limit, readtimeout)

t = HTTP.Transaction(conn)
@code_warntype HTTP.handle(h, t, false)

stream = HTTP.Stream(HTTP.Request(), t)
@code_warntype HTTP.handle(h, stream)