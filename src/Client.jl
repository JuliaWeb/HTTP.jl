require("HTTP")
require("Calendar")

module HTTPClient
  include("Common/Parser.jl")
  
  import HTTP
  import Base
  import Base.IPv4, Base.IPv6
  
  type Connection
    host::Union(IPv4, IPv6)
    port::Integer
    socket::TcpSocket
  end
  
  function open(_host::Union(IPv4, String), port::Integer)
    host::IPv4 = (isa(_host, String) ? Base.getaddrinfo(_host) : _host)
    socket = TcpSocket()
    
    Base.connect(socket, host, uint8(port))
    
    conn = Connection(host, port, socket)
    return conn
  end
  
  function close(conn::Connection)
    Base.close(conn.socket)
  end
  
end
