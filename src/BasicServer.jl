require("Calendar")

module BasicServer
  
  using HTTP
  using Base
  
  include("BasicServer/Parser.jl")
  
  function read_handler(client::TcpSocket, app, debug)
    try
      _start = time()
      
      request = handle_request(client)
      if request.method == "POST" || request.method == "PUT"
        handle_data(request, client)
      end
      response = handle_response(request, app)
      Base.write(client, build_response(response))
      
      _elapsed = time() - _start
      log(request, response, _elapsed)
    finally
      Base.close(client)
      return true
    end
  end
  
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
    
    try
      # keepalive = true
      # while keepalive
        request = handle_request(client)
      
        if request.method == "POST" || request.method == "PUT"
          handle_data(request, client)
        end
        
        response, elapsed = @timed handle_response(request, app)
      
        Base.write(client, build_response(response))
        
        log(request, response, elapsed)
        
        # if request.headers["Connection"][1] == "keep-alive"
        #   keepalive = true
        # else
          # TODO: Make keepalive functional (requires putting a timeout on the
          # or else it will get stuck in a loop if a client drops
          # a connection).
          # keepalive = false
        # end
      # end#while keepalive
      
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
    
    Base.close(client)
  end#accept_handler
  
  function log(request, response, elapsed)
    # Sinatra's pretty log format:
    # 127.0.0.1 - - [29/Jan/2013 12:31:51] "GET / HTTP/1.1" 200 11 0.0006
    
    # Makes a float into a pretty "12.345" string
    function format(e)
      s = int(floor(e))
      msec = int((e - floor(e)) * 1000)
      return string(s) * "." * lpad(string(msec), 3, "0")
    end
    
    fullpath = request.path
    if length(request.query_string) > 0
      fullpath = fullpath*"?"*request.query_string
    end  
    println(request.method*" "*fullpath*" "*string(response.status)*" "*format(elapsed))
  end
  
  function read_block(client)
    # Accept lines until you hit a double-newline
    raw = ""
    nb = true
    while nb
      line = Base.readline(client)
      raw = raw * line
      # readline also got one newline, so just need to check for a single.
      if line == "\r\n" || line == "\n"
        nb = false
      end
    end
    return raw
  end
  
  function handle_data(request, client)
    content_length = int(request.headers["Content-Length"][1])
    binary = Base.read(client, Uint8, content_length)
    request.raw_data = UTF8String(binary)
    
    if has(request.headers, "Content-Type") && has(Set(request.headers["Content-Type"]...), "application/x-www-form-urlencoded")
      request.data = Parser.parse_query(request.raw_data)
    end
  end
  
  function handle_request(client)
    raw_request = read_block(client)
    
    request = HTTP.Request()
    
    request_line, raw_header = split(raw_request, "\n", 2)
    
    method, path, version = Parser.parse_request_line(request_line)
    request.method = method
    parts = split(path, "?", 2)
    request.path = parts[1]
    if length(parts) == 2
      request.query_string = parts[2]
    end
    request.version = version
    
    request.headers = Parser.parse_header(raw_header)
    if has(request.headers, "Cookie")
      request.cookies = Parser.parse_cookies(join(request.headers["Cookie"], "; "))
    end
    
    return request
  end
  
  function handle_response(request, app)
    not_found = HTTP.Response(404, "Not found") # "HTTP/1.1 404 Not found\r\n\r\nNot found\n"
    internal_error = HTTP.Response(500, "Internal server error (no app)") # "HTTP/1.1 500 Server error\r\n\r\nInternal server error (no app)\n"
    
    if isa(app, Function)
      response = HTTP.Response()
      ret = app(request, response)
      if isequal(ret, nothing)
        return not_found
      else
        if isa(ret, Array)
          response.status = ret[1]
          response.body = string(ret[2])
        elseif isa(ret, String)
          response.body = ret
        elseif ret == false
          return not_found
        elseif ret == true
          # Pass
        else
          error("Unexpected response format '"*string(typeof(ret))*"' from app function")
        end
        
        return response
      end
    else
      return internal_error
    end
  end
  
  function bind_no_event(port, app, debug)
    return listen(port) do sock, status
      client = accept(sock)
      #client.readcb = (args...)->(show(args);println();read_handler(client, app, debug);true)
      client.readcb = (socket, n)->(read_handler(client, app, debug))
      start_reading(client)
    end
  end
  
  function bind(port, app, debug)
    socket = bind_no_event(port, app, debug)
    if debug; println("Listening on $(string(port))..."); end
    Base.event_loop(false)
    close(socket)
    return
    
    # addr = Base.InetAddr(IPv4(uint32(0)), uint16(port)) # host, port
    # socket = TcpSocket()
    # if Base.bind(socket, addr) != true
    #   error("bind: could not bind to socket")
    #   return
    # end
    # 
    # socket.ccb = (handle, status) -> accept_handler(handle, status, app, debug)
    # if listen(socket) != true
    #   error("listen: could not listen on socket")
    # end
    # socket.open = true
    # 
    # if debug; println("Listening on $(string(port))..."); end
    # Base.event_loop(false)
    # 
    # close(socket)
  end#bind
  
  # Default has debug disabled
  bind(port, app) = bind(port, app, false)
  
  function build_response(response::HTTP.Response)
    return "HTTP/1.1 "*string(response.status)*build_headers(response)*"\r\n\r\n"*response.body
  end
  
  function build_headers(response::HTTP.Response)
    headers = String[]
    
    if has(response.headers, "Content-Length")
      # Grab the first Content-Length in the headers
      content_lengths = delete!(response.headers, "Content-Length")
      # TODO: Refactor this to be prettier
      if isa(content_lengths, String)
        content_length = content_lengths
      else
        content_length = content_lengths[1]
      end
    else
      content_length = length(response.body)
    end
    
    # TODO: Support keep-alive connections (see accept_handler above).
    if has(response.headers, "Connection")
      delete!(response.headers, "Connection")
    end
    push!(headers, "Connection: close")
    
    push!(headers, "Content-Length: "*string(content_length))
    
    for pairs in response.headers
      key, values = pairs
      # TODO: Refactor this to be prettier
      if isa(values, String)
        push!(headers, key*": "*values)
      else
        for value in values
          push!(headers, key*": "*value)
        end
      end
    end
    
    for cookie in response.cookies
      push!(headers, HTTP.cookie_header(cookie))
    end
    
    final = "\r\n" * join(headers, "\r\n")
    
    return final
  end#build_headers
  
end
