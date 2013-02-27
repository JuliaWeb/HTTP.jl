require("src/HTTP")
require("src/BasicServer")

function test_app(req, res)
  if isequal(req.path, "/")
    
    #println(req.cookies)
    
    #show(req.path)
    
    # res.headers["X-Other"] = "test"
    
    sleep(rand())
    
    return "Body"
  elseif isequal(req.path, "/error")
    return [500, "Special error\n"]
  else
    return nothing
  end
end

BasicServer.bind(8000, test_app, true)

# #post_data = "Name=Jonathan+Doe&Age=23&Formula=a+%2B+b+%3D%3D+13%25%21"
# #data = Parser.parse_query(post_data)
# #println(data)
# 
# #println(BasicServer.Parser.escape_form("a + b = 3%!"))
# 
# require("src/HTTP")
# 
# c1 = HTTP.new_cookie("key", "value")
# println(c1)
# 
# c2 = HTTP.new_cookie("key", "value", {:expires => Calendar.now() + Calendar.years(10)})
# println(HTTP.cookie_header(c2))
# 
# # c3 = HTTP.new_cookie("key", "value")
# # println(c3)

