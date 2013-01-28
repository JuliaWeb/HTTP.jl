module BasicServer
  
  using HTTP
  using Base
  
  include("BasicServer/Parser.jl")
  
  function accept_handler(server::TcpSocket, status::Int32, app, debug)
    if status != 0
      uv_error("Error (" * string(status) * ")")
    end
    client = TcpSocket()
    err = accept(server, client)
    if err != 0
      uv_error("accept error: " * string(err))
      return
    end
    
    response_data = ""
    try
      # Accept lines until you hit a double-newline
      raw = ""
      nb = true
      while nb
        #line = readline(iostream)
        line = Base.readline(client)
        raw = raw * line
        if line == "\r\n" || line == "\n"
          nb = false
        end
      end
    
      parts = split(raw, "\r")
      raw = join(parts, "")
      requests = vec(split(raw, "\n\n"))
    
      #response_data = handle_request(strip(header))
      
      while length(requests) > 0
        resp = handle_request(requests, app)
        if resp != nothing
          response_data = response_data * resp
        end
      end
    catch e
      println(e)
      # TODO: Fix this so it can show a better output
      # Current output if error happens with no try-catch block:
      #   
      #   accept error: -1: resource temporarily unavailable (EAGAIN)
      #    in uv_error at stream.jl:470
      #    in accept_handler at /Users/dirk/.julia/HTTP/src/BasicServer.jl:15
      #    in anonymous at /Users/dirk/.julia/HTTP/src/BasicServer.jl:64
      #    in _uv_hook_connectioncb at stream.jl:200
      #    in event_loop at multi.jl:1392
      #    in bind at /Users/dirk/.julia/HTTP/src/BasicServer.jl:71
      #    in include_from_node1 at loading.jl:76
      #    in process_options at client.jl:259
      #    in _start at client.jl:322
    end
    
    # Write all the responses and close
    Base.write(client, response_data)
    Base.close(client)
  end#accept_handler
  
  function bind(port, app, debug)
    addr = Base.InetAddr(Base.IPv4(uint32(0)), uint16(port)) # host, port
    socket = TcpSocket()
    if Base.bind(socket, addr) != true
      error("bind: could not bind to socket")
      return
    end
    socket.ccb = (handle, status) -> accept_handler(handle, status, app, debug)
    if listen(socket) != true
      error("listen: could not listen on socket")
    end
    socket.open = true
    
    if debug; println("Looping..."); end
    Base.event_loop(false)
    
    close(socket)
  end#bind
  
  # Default has debug disabled
  bind(port, app) = bind(port, app, false)
  
  function handle_request(requests, app)
    if length(requests) == 0
      return nothing
    end
    
    raw_request = strip(shift!(requests))
    if length(raw_request) == 0
      return nothing
    end
    
    request = HTTP.Request()
    response = HTTP.Response()
    
    request_line, raw_header = split(raw_request, "\n", 2)
    
    method, path, version = Parser.parse_request_line(request_line)
    request.method = method
    request.path = path
    request.version= version
    
    request.headers = Parser.parse_header(raw_header)
    if has(request.headers, "Cookie")
      request.cookies = Parser.parse_cookies(join(request.headers["Cookie"], "; "))
    end
    
    if isequal(request.method, "POST") && count(requests) > 0
      request.data = Parser.parse_query(shift!(requests))
    end
    
    not_found = "HTTP/1.1 404 Not found\r\n\r\nNot found\n"
    internal_error = "HTTP/1.1 500 Server error\r\n\r\nInternal server error (no app)\n"
    
    if isa(app, Function)
      ret = app(request, response)
      if isequal(ret, nothing)
        return not_found
      else
        status = string(ret[1])
        body = string(ret[2])
        return "HTTP/1.1 "*status*"\r\n\r\n"*body
      end
    else
      return internal_error
    end
    
  end#handle_request
  
end
