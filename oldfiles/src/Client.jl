require("HTTP")
require("Calendar")

module HTTPClient
  include("Common/Parser.jl")
  
  import HTTP
  import Base
  import Base.IPv4
  
  const CRLF = "\x0d\x0a"
  
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
  
  
  function handle_response(conn::Connection)
    res_str = ""
    cont = true
    while cont
      line = Base.readline(conn.socket)
      res_str = res_str * line
      # readline also got one newline, so just need to check for a single.
      if line == CRLF
        cont = false
      end
    end
    response_line, raw_header = split(res_str, CRLF, 2)
    
    version, status, phrase = Parser.parse_response_line(response_line)
    
    res = HTTP.Response()
    res.status = int(status)
    res.phrase = phrase
    res.headers = Parser.parse_header(raw_header)
    
    if has(res.headers, "Content-Length")
      cl = res.headers["Content-Length"]
      if isa(cl, Array); cl = cl[1]; end
      cl = int(cl)
      raw = Base.read(conn.socket, Uint8, cl)
      res.body = UTF8String(raw)
      return res
    end
    if has(res.headers, "Transfer-Encoding")
      te = res.headers["Transfer-Encoding"]
      if isa(te, Array); te = te[1]; end
      if te != "chunked"
        throw("Unrecognized Transfer-Encoding: $(te)")
      end
      
      body = ""
      chunk_size = strip(Base.readline(conn.socket))
      while chunk_size != "0"
        chunk = Base.read(conn.socket, Uint8, parse_hex(chunk_size))
        body *= UTF8String(chunk)
        
        sep = Base.readline(conn.socket)
        if sep != CRLF
          throw("Unrecognized chunk separator: $(sep)")
        end
        chunk_size = strip(Base.readline(conn.socket))
      end
      res.body = body
      return res
    end
    
    body = ""
    while conn.socket.open
      line = Base.readline(conn.socket)
      body *= line
    end
    res.body = body
    return res
  end
  
  function default_request()
    req = HTTP.Request()
    req.version = "1.1"
    return req
  end
  
  function get(conn::Connection, req::HTTP.Request)
    req.headers["Cookie"] = "test=test"
    req_str = build_request(conn, req)
    write(conn.socket, req_str)
    
    handle_response(conn)
    
    
  end
  
  function get(conn::Connection, path::String)
    req = default_request()
    req.method = "GET"
    req.path = path
    return get(conn, req)
  end
  
  function build_request(conn::Connection, req::HTTP.Request)
    s = "$(req.method) $(req.path) HTTP/$(req.version)\n"
    if has(req.headers, "Host")
      val = dict[param]
      if isa(val, Array)
        val = val[1]
      end
      s *= "Host: $(val)\n"
    else
      s *= "Host: $(conn.host)\n"
    end
    for (key, value) in req.headers
      s *= key*": "*string(value)*"\n"
    end
    s *= "\n"
    return s
  end
  
end
