require("HTTP/Ocean")

using Ocean

app = new_app()

get(app, "/", function(req, res, _)
  return "testing"
end)

get(app, pr"/:test", function(req, res, _)
  println(_.params)
  return _.redirect("/")
end)

BasicServer.bind(8000, binding(app), true)
