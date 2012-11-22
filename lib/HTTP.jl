# HTTP.jl
# Authors: Dirk Gadsden

# HTTP parsing functionality adapted from Webrick parsing.
# http://www.ruby-doc.org/stdlib-1.9.3/libdoc/webrick/rdoc/WEBrick/HTTPUtils.html#method-c-parse_header
# 
# def parse_header(raw)
#   header = Hash.new([].freeze)
#   field = nil
#   raw.each_line{|line|
#     case line
#     when %r^([A-Za-z0-9!\#$%&'*+\-.^_`|~]+):\s*(.*?)\s*\z/m
#       field, value = $1, $2
#       field.downcase!
#       header[field] = [] unless header.has_key?(field)
#       header[field] << value
#     when %r^\s+(.*?)\s*\z/m
#       value = $1
#       unless field
#         raise HTTPStatus::BadRequest, "bad header '#{line}'."
#       end
#       header[field][-1] << " " << value
#     else
#       raise HTTPStatus::BadRequest, "bad header '#{line}'."
#     end
#   }
#   header.each{|key, values|
#     values.each{|value|
#       value.strip!
#       value.gsub!(%r\s+/, " ")
#     }
#   }
#   header
# end
# 
# def read_request_line(socket)
#   @request_line = read_line(socket) if socket
#   @request_time = Time.now
#   raise HTTPStatus::EOFError unless @request_line
#   if /^(\S+)\s+(\S+?)(?:\s+HTTP\/(\d+\.\d+))?\r?\n/mo =~ @request_line
#     @request_method = $1
#     @unparsed_uri   = $2
#     @http_version   = HTTPVersion.new($3 ? $3 : "0.9")
#   else
#     rl = @request_line.sub(/\x0d?\x0a\z/o, '')
#     raise HTTPStatus::BadRequest, "bad Request-Line `#{rl}'."
#   end
# end

module HTTP
  using Base
  import Base.+
  +(a::ASCIIString,b::ASCIIString) = strcat(a, b)
  
  #require("parse.jl")
  module Parse
    using Base
  
    function parse_header(raw::String)
      header = Dict{String, Any}()
      field = nothing
    
      lines = split(raw, "\n")
      for line in lines
        line = strip(line)
        if isempty(line) continue end
      
        matched = false
        m = match(r"^([A-Za-z0-9!\#$%&'*+\-.^_`|~]+):\s*(.*?)\s*\z"m, line)
        if m != nothing
          field, value = m.captures[1], m.captures[2]
          if has(header, field)
            push(header[field], value)
          else
            header[field] = {value}
          end
          matched = true
        
          field = nothing
        end
      
        m = match(r"^\s+(.*?)\s*\z"m, line)
        if m != nothing && !matched
          value = m.captures[1]
          if field == nothing
          
            continue
          end
          ti = length(header[field])
          header[field][ti] = strcat(header[field[ti]], " ", value)
          matched = true
        
          field = nothing
        end
      
        if matched == false
          throw(strcat("Bad header: ", line))
        end
       
      
      end
    
      return header
    end
  
    function parse_request_line(request_line)
      m = match(r"^(\S+)\s+(\S+?)(?:\s+HTTP\/(\d+\.\d+))?"m, request_line)
      if m == nothing
        throw(strcat("Bad request: ", request_line))
        return
      else
        method = string(m.captures[1])
        path = string(m.captures[2])
        version = string((length(m.captures) > 2 && m.captures[3] != nothing) ? m.captures[3] : "0.9")
      end
      return vec([method, path, version])
    end
  
    export parse_header, parse_request_line
  
  end
  
  
  type Request
    method::String
    path::String
    headers::Dict{String,Any}
    version::String
    data::String
  end
  Request() = Request("", "", Dict{String,Any}(), "", "")
  
  type Response
    headers::Dict{String,Any}
  end
  Response() = Response(Dict{String,Any}())
  
end

# Eventually we'll be able to do load("basic_server.jl") but for now it has
# to be defined here.
module BasicServer
  using Base
  import Base.+
  +(a::ASCIIString,b::ASCIIString) = strcat(a, b)
  
  using HTTP
  
  function bind(port, app)
    println("Opening...")
    
    sockfd = ccall(:open_any_tcp_port, Int32, (Ptr{Int16},), [int16(port)])
    println("sockfd: "+string(sockfd))
    if sockfd == -1
      println("Error opening")
      return
    end
    
    header = ""
    lastline = ""
    
    println("Serving...")
    
    iter = 0
    
    while true
      println("iter: "+string(iter))
      
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
    
    method, path, version = HTTP.Parse.parse_request_line(request_line)
    request.method = method
    request.path = path
    request.version= version
    
    request.headers = HTTP.Parse.parse_header(raw_header)
    
    if isequal(request.method, "POST") && count(requests) > 0
      request.data = shift(requests)
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
  end
  
  
end


function test_app(req, res)
  if isequal(req.path, "/")
    return {200, "Body\n"}
  else
    return nothing
  end
end

BasicServer.bind(8000, test_app)
