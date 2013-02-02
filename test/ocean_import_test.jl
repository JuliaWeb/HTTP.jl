require("HTTP/Ocean")

using Ocean

app = new_app()

println(app)

any(app, "/", function(req, res, _)
  return "testing"
end)

BasicServer.bind(8000, binding(app), true)
