# Median-of-trials comparison table from results/*.txt
#   julia bench/websocket/compare.jl [results_dir]
using Statistics

dir = length(ARGS) >= 1 ? ARGS[1] : joinpath(@__DIR__, "results")

# results[version][scenario][metric] = [trial values...]
results = Dict{String,Dict{String,Dict{String,Vector{Float64}}}}()
for f in readdir(dir; join=true)
    m = match(r"(v[12])_trial\d+\.txt$", f)
    m === nothing && continue
    v = m.captures[1]
    for line in eachline(f)
        startswith(line, "RESULT ") || continue
        fields = Dict{String,String}()
        for tok in split(chopprefix(line, "RESULT "))
            kv = split(tok, '='; limit=2)
            length(kv) == 2 && (fields[kv[1]] = kv[2])
        end
        name = fields["name"]
        for (k, val) in fields
            k == "name" && continue
            x = tryparse(Float64, val)
            x === nothing && continue
            push!(get!(get!(get!(results, v, Dict()), name, Dict()), k, Float64[]), x)
        end
    end
end

med(v, s, k) = haskey(results, v) && haskey(results[v], s) && haskey(results[v][s], k) ?
               median(results[v][s][k]) : NaN

scenarios = sort(collect(union([keys(get(results, v, Dict())) for v in ("v1", "v2")]...)))
println(rpad("scenario", 14), " | ", rpad("metric", 10), " | ", lpad("v1 (1.11)", 12), " | ",
        lpad("v2 (2.x)", 12), " | ", lpad("v2/v1", 7))
println("-"^14, "-+-", "-"^10, "-+-", "-"^12, "-+-", "-"^12, "-+-", "-"^7)
for s in scenarios
    metrics = startswith(s, "latency") ? ["p50_us", "p90_us", "p99_us"] :
              ["msgs_s", "mb_s", "allocs_per_msg", "kb_per_msg", "gc_pct"]
    for k in metrics
        a = med("v1", s, k); b = med("v2", s, k)
        (isnan(a) && isnan(b)) && continue
        ratio = b / a
        println(rpad(s, 14), " | ", rpad(k, 10), " | ", lpad(round(a; digits=2), 12), " | ",
                lpad(round(b; digits=2), 12), " | ", lpad(round(ratio; digits=2), 7))
    end
end
