require("HTTP")
require("Calendar")

module HTTPClient
  include("Common/Parser.jl")
  
  import HTTP
  import Base
  import Base.IPv4
  
  type Connection
    host::Union(String, IPv4)
    port::Integer
    socket::TcpSocket
  end
  
  function open(host::Union(IPv4, String), port::Integer)
    host_ip::IPv4 = (isa(host, String) ? Base.getaddrinfo(host) : host)
    socket = TcpSocket()
    
    Base.connect(socket, host_ip, uint8(port))
    
    conn = Connection(host, port, socket)
    return conn
  end
  
  function close(conn::Connection)
    Base.close(conn.socket)
  end
  
  
  function default_request()
    req = HTTP.Request()
    req.version = "1.1"
    return req
  end
  
  function get(conn::Connection, path::String)
    req = default_request()
    req.method = "GET"
    req.path = path
    
    str = build_request(conn, req)
    println(str)
    
    
  end
  
  function build_request(conn::Connection, req::HTTP.Request)
    s = "$(req.method) $(req.path) HTTP/$(req.version)\n"
    s *= "Host: $(conn.host)\n"
    
    s *= "\n"
    return s
  end
  
end
