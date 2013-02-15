
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
  
  # PARSING
  
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
    # Reverting to old regex for the non-capturing group because the "HTTP/n.n"
    # isn't required in older versions of HTTP.
    m = match(r"^(\S+)\s+(\S+)(?:\s+HTTP\/(\d+\.\d+))?"m, request_line)
    # m = match(r"^(\S+)\s+(\S+)\s+HTTP\/(\d+\.\d+)"m, request_line)
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
  
  function parse_query(str, separators)
    query = Dict{String,Any}()
    if isa(str, String)
      str = strip(str)
      parts = split(str, separators)
      for part in parts
        part = strip(part)
        if isempty(part) next; end
        
        key, value = split(part, "=", 2)
        key   = unescape_form(key)
        value = unescape_form(value)
        if has(query, key)
          push(query[key], value)
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
  
  # export parse_header, parse_request_line, parse_query, parse_cookies
  
  # /PARSING
  
  
  
  
  # ESCAPING
  # TODO: Make it use the escaping functions now in HTTP.Util.
  
  # Unescaping
  escaped_regex = r"%([0-9a-fA-F]{2})"
  function unescape(str)
    # def _unescape(str, regex) str.gsub(regex){ $1.hex.chr } end
    for m in each_match(escaped_regex, str)
      for capture in m.captures
        rep = string(char(parse_int(capture, 16)))
        str = replace(str, "%"*capture, rep)
      end
    end
    return str
  end
  function unescape_form(str)
    str = replace(str, "+", " ")
    return unescape(str)
  end
  
  # Escaping
  control_array = convert(Array{Uint8,1}, vec(0:(parse_int("1f", 16))))
  control = utf8(ascii(control_array)*"\x7f")
  space = utf8(" ")
  delims = utf8("%<>\"")
  unwise   = utf8("{}|\\^`")
  nonascii_array = convert(Array{Uint8,1}, vec(parse_int("80", 16):(parse_int("ff", 16))))
  #nonascii = utf8(string(nonascii_array))
  reserved = utf8(",;/?:@&=+\$![]'*#")
  # Strings to be escaped
  # (Delims goes first so '%' gets escaped first.)
  unescaped = delims * reserved * control * space * unwise# * nonascii
  unescaped_form = delims * reserved * control * unwise# * nonascii
  
  # Escapes chars (listed in second string); also escapes all non-ASCII chars.
  function escape_with(str, use)
    chars = split(use, "")
    
    for c in chars
      _char = c[1] # Character string as Char
      h = hex(int(_char))
      if length(h) < 2
        h = "0"*h
      end
      str = replace(str, c, "%" * h)
    end
    
    for i in nonascii_array
      str = replace(str, char(i), "%" * hex(i))
    end
    
    return str
  end
  
  function escape(str)
    return escape_with(str, unescaped)
  end
  function escape_form(str)
    str = escape_with(str, unescaped_form)
    return replace(str, " ", "+")
  end
  
  # export unescape, unescape_form, escape, escape_form
  
end
