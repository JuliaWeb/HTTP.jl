#run Proc.new {|env| [200, {"Content-Type" => "text/html"}, "Hello Rack!"]}
run Proc.new {|env| nil }

