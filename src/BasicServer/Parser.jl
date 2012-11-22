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
  
  export parse_header, parse_request_line
  
end
