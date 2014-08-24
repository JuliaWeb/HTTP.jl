
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
# 
# def parse_query(str)
#   query = Hash.new
#   if str
#     str.split(%r[&;]/).each{|x|
#       next if x.empty?
#       key, val = x.split(%r=/,2)
#       key = unescape_form(key)
#       val = unescape_form(val.to_s)
#       val = FormData.new(val)
#       val.name = key
#       if query.has_key?(key)
#         query[key].append_data(val)
#         next
#       end
#       query[key] = val
#     }
#   end
#   query
# end

module Parser
  using Base
  import HTTP
  
  const CR   = "\x0d"
  const LF   = "\x0a"
  const CRLF = "\x0d\x0a"
  
  # PARSING
  
  function parse_header(raw::String)
    header = Dict{String, Any}()
    field = nothing
    
    lines = split(raw, "\n")
    for line in lines
      line = strip(line)
      if isempty(line); continue; end
      
      matched = false
      m = match(r"^([A-Za-z0-9!\#$%&'*+\-.^_`|~]+):\s*(.*?)\s*\z"m, line)
      if m != nothing
        field, value = m.captures[1], m.captures[2]
        if haskey(header, field)
          push!(header[field], value)
        else
          header[field] = {value}
        end
        matched = true
        
        field = nothing
      end
      
      m = match(r"^\s+(.*?)\s*\z"m, line)
      if m != nothing && !matched
        value = m.captures[1]
        if field == nothing; continue; end
        ti = length(header[field])
        header[field][ti] = header[field[ti]] * " " * value
        matched = true
        
        field = nothing
      end
      
      if matched == false
        throw("Bad header: " * line)
      end
    end
    
    return header
  end
  
  function parse_request_line(request_line)
    # Reverting to old regex for the non-capturing group because the "HTTP/n.n"
    # isn't required in older versions of HTTP.
    m = match(r"^(\S+)\s+(\S+)(?:\s+HTTP\/(\d+\.\d+))?"m, request_line)
    # m = match(r"^(\S+)\s+(\S+)\s+HTTP\/(\d+\.\d+)"m, request_line)
    if m == nothing
      throw("Bad request: " * request_line)
      return
    else
      method = string(m.captures[1])
      path = string(m.captures[2])
      version = string((length(m.captures) > 2 && m.captures[3] != nothing) ? m.captures[3] : "0.9")
    end
    return (method, path, version)
  end
  
  function parse_response_line(request_line)
    m = match(r"^HTTP\/(\d+\.\d+) (\d{3}) ?(.*)$", request_line)
    version = m.captures[1]
    status  = m.captures[2]
    phrase  = m.captures[3]
    return (version, status, phrase)
  end
  
  function parse_query(str, separators)
    query = Dict{String,Any}()
    if isa(str, String)
      str = strip(str)
      parts = split(str, separators)
      for part in parts
        part = strip(part)
        if isempty(part); next; end
        
        p = search(part, '=')
        if p > 0
          key = part[1:p-1]
          value = part[p+1:end]
        else
          # p = 0 if '=' not found
          key = part
          value = ""
        end
        key   = HTTP.Util.unescape_form(key)
        value = HTTP.Util.unescape_form(value)
        if haskey(query, key)
          push!(query[key], value)
        else
          query[key] = [value]
        end
      end
    end
    return query
  end
  parse_query(str) = parse_query(str, r"[&;]")
  
  function parse_cookies(cookie_str)
    return parse_query(cookie_str, r"[;,]\s*")
  end
  
  function _chop(s::String)
    if ends_with(s, CRLF)
      chop(chop(s))
    elseif ends_with(s, LF)
      chop(s)
    end
  end
  
  function parse_form_data(request, client, boundary::String)
    boundary_start = "--"*boundary
    boundary_regex = Regex("^--"*boundary*"(--)?(?:(?:"*LF*")|(?:"*CRLF*"))\$")
    
    # Stores tuples of headers and raw data
    datas = Any[]
    
    header_lines = String[]
    # data_lines = String[]
    data_buf = memio()
    parsing_header = true
    
    while true
      line = Base.readline(client)
      
      if beginswith(line, boundary_start)
        _match = match(boundary_regex, line)
        if length(header_lines) > 0# && length(data_lines) > 0
          headers = join(header_lines, "\n")
          # data = join(data_lines, "")
          data = takebuf_string(data_buf)
          close(data_buf)
          push!(datas, (headers, data))
        end
        # End of form data
        if _match.captures[1] == "--"
          break
        end
        # Reset
        header_lines = String[]
        data_lines = String[]
        parsing_header = true
      else
        # CRLF separates header and data
        if line == CRLF && parsing_header
          parsing_header = false
        else
          if parsing_header
            push!(header_lines, _chop(line))
          else
            write(data_buf, line)
          end
        end
      end
    end
    
    ret = Dict{String,Any}()
    
    for pairs in datas
      raw_headers, data = pairs
      headers = parse_header(raw_headers)
      
      if !haskey(headers, "Content-Disposition")
        error("Multipart blocks must provide a Content-Disposition header")
      else
        disp = headers["Content-Disposition"][1]
      end
      
      _nm = match(r"\s+name=\"([^\"]+)\"", disp)
      if _nm != nothing
        name = _nm.captures[1]
      else
        error("Multipart blocks must provide a name")
      end
      
      _fm = match(r"\s+filename=\"([^\"]+)\"", disp)
      if _fm != nothing
        filename = _fm.captures[1]
      else; filename = false; end
      
      if filename != false && haskey(headers, "Content-Type")
        mp = HTTP.Multipart()
        mp.name = name
        mp.headers = headers
        mp.filename = filename
        mp.mime_type = headers["Content-Type"][1]
        mp.data = data
        
        ret[name] = [mp]
      else
        ret[name] = [strip(data)]
      end
    end
    
    return ret
  end
  
  # export parse_header, parse_request_line, parse_query, parse_cookies
  
  # /PARSING
end
