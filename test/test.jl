require("HTTP")

function test_app(req, res)
  if isequal(req.path, "/")
    return {200, "Body\n"}
  else
    return nothing
  end
end

#BasicServer.bind(8000, test_app)
