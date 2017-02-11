require("Calendar")

module BasicServer

  using HTTP
  using Base

  const CR   = "\x0d"
  const LF   = "\x0a"
  const CRLF = "\x0d\x0a"

  include("Common/Parser.jl")

  function read_handler(client::Base.TcpSocket, app, debug)
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
    catch e
      Base.error_show(OUTPUT_STREAM, e, backtrace())
      println()
    finally
      Base.close(client)
      return true
    end
  end

  function accept_handler(server::Base.TcpServer, status::Int32, app, debug)
    if status != 0
      error("Error (" * string(status) * ")")
    end
    client = Base.accept(server)
    if client.status == -1
      error("accept error")
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

        built_response = build_response(response)

        Base.write(client, built_response)

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
      Base.showerror(Base.STDOUT, e, catch_backtrace())
      println()
    finally
      Base.close(client)
      return true
    end
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
      if line == CRLF || line == LF
        nb = false
      end
    end
    return raw
  end

  function handle_data(request, client)
    if haskey(request.headers, "Content-Type")
      if length(request.headers["Content-Type"]) != 1
        error("Only one Content-Type header allowed")
      end
      ctype::String = request.headers["Content-Type"][1]

      println("ctype: " * ctype)

      if ctype == "application/x-www-form-urlencoded"
        content_length = int(request.headers["Content-Length"][1])
        binary = Base.read(client, Uint8, content_length)
        request.raw_data = UTF8String(binary)
        request.data = Parser.parse_query(request.raw_data)
      elseif beginswith(ctype, "multipart/form-data")
        _match = match(r"multipart\/form-data; boundary=(.+)", ctype)
        boundary = _match.captures[1]

        println("boundary: " * boundary)
        println("Calling parse_form_data")
        request.data = Parser.parse_form_data(request, client, boundary)
        println("There")
      else
        error("Unrecognized Content-Type: $ctype")
      end
    end
  end

  function handle_request(client)

    raw_request = read_block(client)

    request = HTTP.Request()

    request_line, raw_header = split(raw_request, CRLF, 2)

    method, path, version = Parser.parse_request_line(request_line)
    request.method = method
    parts = split(path, "?", 2)
    request.path = parts[1]
    if length(parts) == 2
      request.query_string = parts[2]
    end
    request.version = version

    request.headers = Parser.parse_header(raw_header)
    if haskey(request.headers, "Cookie")
      request.cookies = Parser.parse_cookies(
        join(request.headers["Cookie"], "; ")
      )
    end

    return request
  end

  function handle_response(request, app)
    not_found = HTTP.Response(404, "Not found")
    # "HTTP/1.1 404 Not found\r\n\r\nNot found\n"
    internal_error = HTTP.Response(500, "Internal server error (no app)")
    # "HTTP/1.1 500 Server error\r\n\r\nInternal server error (no app)\n"

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
    # return listen(port) do sock, status
    #   client = accept(sock)
    #   #client.readcb = (args...)->(show(args);println();read_handler(client, app, debug);true)
    #   client.readcb = (socket, n)->(read_handler(client, app, debug))
    #   start_reading(client)
    # end

    addr = Base.IPv4(uint32(0))
    server = Base.listen(addr, port)
    # if Base.bind(socket, addr, port) != true
    #   error("bind: could not bind to socket")
    #   return
    # end

    server.ccb = (handle, status) -> accept_handler(handle, status, app, debug)
    #if listen(socket) != true
    #  error("listen: could not listen on socket")
    #end
    #socket.open = true

    return server
  end

  function bind(port, app, debug)
    socket = bind_no_event(port, app, debug)
    if debug; println("Listening on $(string(port))..."); end
    #Base.event_loop(false)
    wait()
    close(socket)
    return
  end#bind

  # Default has debug disabled
  bind(port, app) = bind(port, app, false)

  function build_response(response::HTTP.Response)
    return "HTTP/1.1 "*string(response.status)*build_headers(response)*"\r\n\r\n"*response.body
  end

  function build_headers(response::HTTP.Response)
    headers = String[]

    if haskey(response.headers, "Content-Length")
      # Grab the first Content-Length in the headers
      # After v0.2:
      #content_lengths = pop!(response.headers, "Content-Length")
      content_lengths = response.headers["Content-Length"]
      delete!(response.headers, "Content-Length")
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
    if haskey(response.headers, "Connection")
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
