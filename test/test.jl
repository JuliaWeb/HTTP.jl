require("src/HTTP")

function test_app(req, res)
  if isequal(req.path, "/")
    
    println(req.cookies)
    
    return {200, "Body\n"}
  else
    return nothing
  end
end

BasicServer.bind(8000, test_app, true)

#post_data = "Name=Jonathan+Doe&Age=23&Formula=a+%2B+b+%3D%3D+13%25%21"
#data = Parser.parse_query(post_data)
#println(data)

#println(BasicServer.Parser.escape_form("a + b = 3%!"))
