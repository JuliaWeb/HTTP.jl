require("HTTP/src/Ocean/Template")

s = "
<% for i = 1:1000 %>
  <%= string(i) %>
<% end %>
"

s2 = "<%= a %>"

macro timeit(name, ex)
    quote
        t = Inf
        for i=1:100
            t = min(t, @elapsed $ex)
        end
        println($name, "\t", t*1000)
    end
end

ct, perf = Template.compile(s)
ct, perf = Template.compile(s)
ct, perf = Template.compile(s)
println("scan\t", perf[:scan_and_generate] * 1000)
println("parse\t", perf[:parse] * 1000)
out, perf = Template.run(ct, {:a => "test"})
out, perf = Template.run(ct, {:a => "test"})
out, perf = Template.run(ct, {:a => "test"})
println("eval\t", perf[:eval] * 1000)
println("join\t", perf[:join] * 1000)
println("reset\t", perf[:reset] * 1000)
#println(out)
