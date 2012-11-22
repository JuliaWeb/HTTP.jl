module BasicServer
  using Base
  import Base.+
  +(a::ASCIIString,b::ASCIIString) = strcat(a, b)
  
  using HTTP
  
  load("HTTP/src/BasicServer/Parser")
  
  function bind(port, app, debug)
    #println("Opening...")
    
    sockfd = ccall(:open_any_tcp_port, Int32, (Ptr{Int16},), [int16(port)])
    #println("sockfd: "+string(sockfd))
    if sockfd == -1
      println("Error opening")
      return
    end
    
    header = ""
    lastline = ""
    
    if debug; println("Serving...") end
    
    iter = 0
    
    while true
      #println("iter: "+string(iter))
      
      connectfd = ccall(:accept, Int32, (Int32, Ptr{Void}, Ptr{Void}), sockfd, C_NULL, C_NULL)
      if connectfd == -1
        println("Error accepting")
        break
      end
      
      println("connectfd: "+string(connectfd))
      iostream = fdio(connectfd)
      
      #raw = readall(iostream)
      raw = ""
      nb = true
      while nb
        line = readline(iostream)
        raw = raw + line
        if line == "\r\n" || line == "\n"
          nb = false
        end
      end
      
      parts = split(raw, "\r")
      raw = join(parts, "")
      requests = vec(split(raw, "\n\n"))
      
      #println(header)
      
      #response_data = handle_request(strip(header))
      response_data = ""
      while length(requests) > 0
        resp = handle_request(requests, app)
        if resp != nothing
          response_data = response_data + resp
        end
      end
      
      write(iostream, response_data)
      close(iostream)
      
      ccall(:close, Int32, (Int32,), connectfd)
      
      iter = iter + 1
    end
    
  end#bind
  
  # Default has debug disabled
  bind(port, app) = bind(port, app, false)
  
  function handle_request(requests, app)
    if length(requests) == 0
      return nothing
    end
    
    raw_request = strip(shift(requests))
    if strlen(raw_request) == 0
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
    
    if isequal(request.method, "POST") && count(requests) > 0
      request.data = Parser.parse_query(shift(requests))
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
        return "HTTP/1.1 "+status+"\r\n\r\n"+body
      end
    else
      return internal_error
    end
    
  end#handle_request
  
end
