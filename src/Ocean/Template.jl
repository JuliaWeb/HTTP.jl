
module TemplateScope
  __buffer = String[]
  __reset = function()
    # __buffer = String[]
    # Assigning it to a new String[] is faster immediately but will probably
    # be paid for later with the GC.
    empty!(__buffer)
  end
end

module Template
  import TemplateScope
  
  type CompiledTemplate
    expr::Expr
  end
  
  # NOTE: Right now most template functions (compile, run) return a tuple with
  #       both their standard return value and a Dict{Symbol,Any} containing
  #       their performance data. This way you can always get a quick look into
  #       how the template library has performaned.
  
  function compile(template::String, header::String)
    perf = Dict{Symbol,Any}()
    perf[:scan_and_generate] = @elapsed (code = scan_and_generate(template, header))
    perf[:parse] = @elapsed (_expr = parse(code))
    return (CompiledTemplate(_expr), perf)
  end
  
  # Parses the template file by tokens and generates the result code.
  function scan_and_generate(t::String, header::String)
    parts = String[]
    
    head = start(t)
    tail = endof(t)
    
    function find_token(tok)
      range = search(t, tok, head)
      st_s = first(range)
      st_e = last(range)
      return (st_s, st_e)
    end
    
    function add_raw(c)
      push!(parts, "push!(__buffer,\"" * escape_string(c) * "\")")
    end
    function add_code(c)
      push!(parts, c)
    end
    function add_code_insert(c)
      push!(parts, "push!(__buffer, begin\n" * c * "\nend)")
    end
    
    # Start by adding the begin block
    add_code("begin\n")
    # Insert the header code (for defining variables and such)
    add_code(header * "\n")
    # Find the first starting token
    st_s, st_e = find_token(r"<%[^%]")
    while head < st_s < st_e <= tail
      # Add the content before the token
      add_raw(t[head:st_s - 1]) # push!(parts, t[head:st_s - 1])
      # Advance the search head to after the opening token
      head = st_e
      # Find the closing token
      et_s, et_e = find_token(r"[^%]%>")
      if head < et_s < et_e <= tail
        # Add the content between the tokens
        # push!(parts, t[head:et_s])
        c = t[head:et_s]
        if begins_with(c, '=')
          add_code_insert(c[2:end])
        else
          add_code(c)
        end
        # Advance the head to after the closing token
        head = et_e + 1
        # Find the next starting token
        st_s, st_e = find_token(r"<%[^%]")
      else
        # TODO: Make this get line numbers
        error("Missing end token around character #" * string(et_e))
      end
    end
    # If there's any left
    if head < tail
      add_raw(t[head:tail]) # push!(parts, t[head:tail])
    end
    # Close with the opening begin block
    add_code("\nend")
    
    return join(parts, "\n")
  end
  
  function run(template::String)
    # perf = Dict{Symbol,Any}()
    # perf[:scan_and_generate] = @elapsed (code = scan_and_generate(template, ""))
    # perf[:parse] = @elapsed (exprs = parse(code))
    
    # TODO: Make header for template with variable definitions.
    ct, perf = compile(template, "")
    
    perf[:eval] = @elapsed (eval(TemplateScope, ct.expr))
    perf[:join] = @elapsed (out = join(TemplateScope.__buffer, ""))
    perf[:reset] = @elapsed (TemplateScope.__reset())
    return (out, perf)
  end
end
