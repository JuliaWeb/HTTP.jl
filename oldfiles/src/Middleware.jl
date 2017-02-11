module Middleware
  # Middleware are wrapper functions around the main app function. They
  # have 3 arguments (app, req, res) instead of the regular two (req, res)
  # and return a function that accepts the regular two like a normal app.
  # However that function exists within the 3-argument closure and calls the
  # closured app function after doing its modifications to the req/res.
  # 
  # The suggested means of action for middleware is to modifiy the req.env
  # dict to send/receive data from the app.
  
  import HTTP
  
  include("Middleware/CookieSession.jl")
end
