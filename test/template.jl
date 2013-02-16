require("HTTP/src/Ocean/Template")


s = "
<% a = 1; b = \"test\" %>
<%= string(a) %>
<%% <%= b %> %%>
"

macro timeit(name, ex)
    quote
        t = Inf
        for i=1:100
            t = min(t, @elapsed $ex)
        end
        println($name, "\t", t*1000)
    end
end

total = @elapsed out, perf = Template.run(s)

perf[:total] = total
#show(perf)
#println()

println("performance (msecs):")
println("scan\t", perf[:scan_and_generate] * 1000)
println("parse\t", perf[:parse] * 1000)
println("eval\t", perf[:eval] * 1000)
println("join\t", perf[:join] * 1000)
println("reset\t", perf[:reset] * 1000)
println("\ntotal\t", perf[:total] * 1000)
