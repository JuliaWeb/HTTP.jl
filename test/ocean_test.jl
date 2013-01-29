require("src/Ocean")

app = Ocean.app()

Ocean.get(app, "/", function(req, res)
  return "test"
end)
