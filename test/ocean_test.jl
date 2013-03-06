require("HTTP/Ocean")
# require("Mustache")

app = Ocean.app()

using Ocean.Util

Ocean.get(app, "/", function(req, res, _)
  res.headers["Content-Type"] = "text/html"
  # f = open(app.source_dir*"/view.html", "r")
  # r = readall(f)
  # close(f)
  
  #println(req.cookies)
  
  v = gs(req.cookies, "test")
  if v != false
    return _.template(:ejl, "view.ejl", {"value" => v})
  else
    return _.file("view.html", false)
  end
  
end)

Ocean.post(app, "/", function(req, res, _)
postdata = gs(req.data, "test")
  if postdata != false
    cookie = HTTP.new_cookie("test", postdata, {:expires => Calendar.now() + Calendar.years(10)})
    HTTP.set_cookie(res, cookie)
  end
  
  if has(req.data, "test_file")
    mp = req.data["test_file"][1]
    
    #tmp = tempname()
    f = open("/Users/dirk/Desktop/8aB8B-test.jpg", "w")
    write(f, mp.data)
    close(f)
    
    #println(tmp)
    #run(`open $(dirname(tmp))`)
  end
  
  return redirect(res, "/")
end)

Ocean.get(app, Ocean.pr("/:test1/:test2"), function(req, res, _)
  println(_.params)
  return _.redirect("/")
end)

Ocean.get(app, r"^/(.+)$", function(req, res, _)
  println(_.params)
  return _.params[1]
  # return false
end)

BasicServer.bind(8000, Ocean.binding(app), true)
