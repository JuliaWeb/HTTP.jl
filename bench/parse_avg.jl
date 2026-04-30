# Parse the 3-run repeated benchmark and produce a summary with
# trimmed-mean throughput + p50/p95/p99 across runs.

using Printf, Statistics

const RESULT_DIR = joinpath(@__DIR__, "results")

function parse_dur(s)
    s = strip(s)
    m = match(r"^([0-9.]+)(us|ms|s|μs)$", s)
    m === nothing && return NaN
    v = parse(Float64, m.captures[1])
    unit = m.captures[2]
    return unit == "s" ? v * 1_000_000 : unit == "ms" ? v * 1_000 : v
end

function parse_file(path)
    d = Dict{String,Any}()
    isfile(path) || return d
    for line in eachline(path)
        if startswith(line, "finished in")
            m = match(r"finished in ([0-9.]+)([smhμ]+), ([0-9.]+) req/s", line)
            m !== nothing && (d["req_s"] = parse(Float64, m.captures[3]))
        elseif startswith(strip(line), "request")
            cols = filter(!isempty, split(strip(line)))
            if length(cols) >= 9
                d["lat_p50"] = parse_dur(cols[5])
                d["lat_p95"] = parse_dur(cols[6])
                d["lat_p99"] = parse_dur(cols[7])
            end
        end
    end
    return d
end

function fmt_us(x)
    isnan(x) && return "—"
    x >= 1_000_000 && return @sprintf("%.2fs", x / 1_000_000)
    x >= 1_000 && return @sprintf("%.2fms", x / 1_000)
    return @sprintf("%.0fµs", x)
end

labels = ["v1-h1", "v2-h1", "v2-h2"]
endpoints = ["tiny", "json", "large"]
concurrencies = [1, 64, 512]
runs = 1:3

# Aggregate: median across runs (more robust than mean to the occasional cold-start outlier)
function agg(label, endpoint, c, key)
    vals = Float64[]
    for r in runs
        path = joinpath(RESULT_DIR, "$(label)_run$(r)", "$(endpoint)_c$(c).txt")
        d = parse_file(path)
        haskey(d, key) && push!(vals, d[key])
    end
    isempty(vals) && return NaN
    return median(vals)
end

mkpath(RESULT_DIR)
open(joinpath(RESULT_DIR, "summary_avg.md"), "w") do io
    println(io, "# h2load benchmark — HTTP.jl 1.x vs 2.0 (median of 3 runs)\n")
    println(io, "Each cell ran 100,000 requests via h2load on macOS aarch64 (14 logical CPUs), Julia with `-t 8`, repeated 3 times. Numbers are the median across the 3 runs to suppress single-run jitter.\n")
    println(io, "## Throughput (req/s, higher is better)\n")
    println(io, "| endpoint | conc | v1 H/1.1 | v2 H/1.1 | v2 H/2 | v2-h1 / v1-h1 | v2-h2 / v1-h1 |")
    println(io, "|---|---|---:|---:|---:|---:|---:|")
    for endpoint in endpoints, c in concurrencies
        v1 = agg("v1-h1", endpoint, c, "req_s")
        v2h1 = agg("v2-h1", endpoint, c, "req_s")
        v2h2 = agg("v2-h2", endpoint, c, "req_s")
        h1ratio = isnan(v1) || isnan(v2h1) ? "—" : @sprintf("%.2fx", v2h1/v1)
        h2ratio = isnan(v1) || isnan(v2h2) ? "—" : @sprintf("%.2fx", v2h2/v1)
        @printf io "| %s | %d | %.0f | %.0f | %.0f | %s | %s |\n" endpoint c v1 v2h1 v2h2 h1ratio h2ratio
    end
    for (lat, name) in [("lat_p50","p50 latency"), ("lat_p95","p95 latency"), ("lat_p99","p99 latency")]
        println(io, "\n## $name (lower is better)\n")
        println(io, "| endpoint | conc | v1 H/1.1 | v2 H/1.1 | v2 H/2 |")
        println(io, "|---|---|---:|---:|---:|")
        for endpoint in endpoints, c in concurrencies
            v1 = agg("v1-h1", endpoint, c, lat)
            v2h1 = agg("v2-h1", endpoint, c, lat)
            v2h2 = agg("v2-h2", endpoint, c, lat)
            @printf io "| %s | %d | %s | %s | %s |\n" endpoint c fmt_us(v1) fmt_us(v2h1) fmt_us(v2h2)
        end
    end
end
println("wrote results/summary_avg.md")
