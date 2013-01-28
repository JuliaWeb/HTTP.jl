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
  
  type Request
    method::String
    path::String
    headers::Dict{String,Any}
    cookies::Dict{String,Any}
    version::String
    data::String
  end
  Request() = Request("", "", Dict{String,Any}(), Dict{String,Any}(), "", "")
  
  type Response
    headers::Dict{String,Any}
  end
  Response() = Response(Dict{String,Any}())
  
end

include("BasicServer.jl")
