
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
# def read_header(socket)
#   if socket
#     while line = read_line(socket)
#       break if /\A(#{CRLF}|#{LF})\z/om =~ line
#       @raw_header << line
#     end
#   end
#   @header = HTTPUtils::parse_header(@raw_header.join)
# end

module HTTP
  using Base
  import Base.+
  
  +(a::ASCIIString,b::ASCIIString) = strcat(a, b)
  
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
  
  function bind(port)
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
      
      nb = true
      while nb
        line = readline(iostream)
        header = header + line
        if line == "\r\n" || line == "\n"
          nb = false
        end
      end
      
      println(header)
      write(iostream, "HTTP/1.0 200 OK\r\nConnection: close\r\n\r\ntest")
      close(iostream)
      
      ccall(:close, Int32, (Int32,), connectfd)
      
      iter = iter + 1
    end
    
    
    
  end
  
  export port
end

#println(HTTP.parse_header("Content-Type: text/plain\nHost: esherido.com"))

HTTP.bind(8000)

