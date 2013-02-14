# require("src/HTTP")
# require("src/BasicServer")
# 
# function test_app(req, res)
#   if isequal(req.path, "/")
#     
#     #println(req.cookies)
#     
#     #show(req.path)
#     
#     # res.headers["X-Other"] = "test"
#     
#     sleep(rand())
#     
#     return "Body"
#   elseif isequal(req.path, "/error")
#     return [500, "Special error\n"]
#   else
#     return nothing
#   end
# end
# 
# BasicServer.bind(8000, test_app, true)

#post_data = "Name=Jonathan+Doe&Age=23&Formula=a+%2B+b+%3D%3D+13%25%21"
#data = Parser.parse_query(post_data)
#println(data)

#println(BasicServer.Parser.escape_form("a + b = 3%!"))

require("src/HTTP")

cookie = HTTP.new_cookie("key", "value", {"domain" => "localhost", :path => "/"})
println(cookie)

type MyType
  member1
  member2
end
mytypeinstance = MyType(1, 2)
mydict = {
  "member1" => 3,
  :member2  => 4
}
HTTP.Util.opts(mydict, mytypeinstance, [:member1, "member2"])
@assert mytypeinstance.member1 == 3
@assert mytypeinstance.member2 == 4

