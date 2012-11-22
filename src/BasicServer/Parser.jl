module Parser
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
  
  function parse_query(str)
    query = Dict{String,Any}()
    if isa(str, String)
      str = strip(str)
      parts = split(str, r"[&;]")
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
  
  #function replace(str, _find, replace)
  #  return join(split(str, _find), replace)
  #end
  
  escaped_regex = r"%([0-9a-fA-F]{2})"
  function unescape(str)
    # def _unescape(str, regex) str.gsub(regex){ $1.hex.chr } end
    for m in each_match(escaped_regex, str)
      for capture in m.captures
        rep = string(char(parse_int(capture, 16)))
        str = replace(str, "%"+capture, rep)
      end
    end
    return str
  end
  
  function unescape_form(str)
    str = replace(str, "+", " ")
    return unescape(str)
  end
  
  export parse_header, parse_request_line
  
end

#post_data = "Name=Jonathan+Doe&Age=23&Formula=a+%2B+b+%3D%3D+13%25%21"
#data = Parser.parse_query(post_data)
#println(data)

