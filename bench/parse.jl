# Parse h2load output files into a CSV / markdown summary.
using Printf

const RESULT_DIR = joinpath(@__DIR__, "results")

function parse_file(path)
    d = Dict{String,Any}()
    for line in eachline(path)
        if startswith(line, "finished in")
            # finished in 3.23s, 30915.05 req/s, 1.12MB/s
            m = match(r"finished in ([0-9.]+)([smhμ]+), ([0-9.]+) req/s, ([0-9.]+)([KMGB]+)", line)
            if m !== nothing
                d["elapsed_s"] = parse(Float64, m.captures[1])
                d["req_s"] = parse(Float64, m.captures[3])
                d["bw"] = m.captures[4] * m.captures[5]
            end
        elseif startswith(line, "requests:")
            m = match(r"(\d+) succeeded, (\d+) failed, (\d+) errored, (\d+) timeout", line)
            if m !== nothing
                d["succeeded"] = parse(Int, m.captures[1])
                d["failed"] = parse(Int, m.captures[2])
                d["errored"] = parse(Int, m.captures[3])
                d["timeout"] = parse(Int, m.captures[4])
            end
        elseif startswith(strip(line), "request")
            # min       max         median    p95       p99      mean       sd        +/- sd
            # whitespace separated
            cols = filter(!isempty, split(strip(line)))
            # cols: ["request", ":", "<min>", "<max>", "<p50>", "<p95>", "<p99>", "<mean>", "<sd>", "<+/-sd>"]
            if length(cols) >= 9
                d["lat_min"] = parse_dur(cols[3])
                d["lat_max"] = parse_dur(cols[4])
                d["lat_p50"] = parse_dur(cols[5])
                d["lat_p95"] = parse_dur(cols[6])
                d["lat_p99"] = parse_dur(cols[7])
                d["lat_mean"] = parse_dur(cols[8])
                d["lat_sd"] = parse_dur(cols[9])
            end
        end
    end
    return d
end

function parse_dur(s)
    s = strip(s)
    m = match(r"^([0-9.]+)(us|ms|s|μs)$", s)
    m === nothing && return NaN
    v = parse(Float64, m.captures[1])
    unit = m.captures[2]
    return unit == "s" ? v * 1_000_000 :  # to microseconds
           unit == "ms" ? v * 1_000 :
           v  # us / μs
end

function fmt_us(x)
    isnan(x) && return "—"
    if x >= 1_000_000
        return @sprintf("%.2fs", x / 1_000_000)
    elseif x >= 1_000
        return @sprintf("%.2fms", x / 1_000)
    else
        return @sprintf("%.0fµs", x)
    end
end

# Build the table
labels = ["v1-h1", "v2-h1", "v2-h2"]
endpoints = ["tiny", "json", "large"]
concurrencies = [1, 64, 512]

# Collect into Dict[(label, endpoint, c)] = parsed dict
results = Dict{Tuple{String,String,Int},Dict{String,Any}}()
for label in labels, endpoint in endpoints, c in concurrencies
    path = joinpath(RESULT_DIR, label, "$(endpoint)_c$(c).txt")
    if isfile(path)
        results[(label, endpoint, c)] = parse_file(path)
    end
end

# CSV output
open(joinpath(RESULT_DIR, "summary.csv"), "w") do io
    println(io, "label,endpoint,concurrency,req_per_s,p50_us,p95_us,p99_us,mean_us,succeeded,failed")
    for label in labels, endpoint in endpoints, c in concurrencies
        d = get(results, (label, endpoint, c), nothing)
        if d !== nothing
            @printf io "%s,%s,%d,%.0f,%.0f,%.0f,%.0f,%.0f,%d,%d\n" label endpoint c get(d,"req_s",NaN) get(d,"lat_p50",NaN) get(d,"lat_p95",NaN) get(d,"lat_p99",NaN) get(d,"lat_mean",NaN) get(d,"succeeded",0) get(d,"failed",0)
        end
    end
end

# Markdown summary
open(joinpath(RESULT_DIR, "summary.md"), "w") do io
    println(io, "# h2load benchmark results: HTTP.jl 1.x vs 2.0\n")
    println(io, "Each cell ran 100,000 requests via h2load on macOS aarch64 (14 logical CPUs), Julia with `-t 8`.")
    println(io, "Server: same `serve!` request handler in both versions, three endpoints:")
    println(io, "")
    println(io, "- `/tiny`  — 200 OK, no body")
    println(io, "- `/json`  — 200 OK, ~150 byte JSON body")
    println(io, "- `/large` — 200 OK, 100 KB body")
    println(io, "")
    println(io, "Concurrency = number of h2load clients. h2load threads scale 1 → 4 → 8.")
    println(io, "")
    println(io, "## Throughput (req/s, higher is better)\n")
    println(io, "| endpoint | conc | v1 HTTP/1.1 | v2 HTTP/1.1 | v2 HTTP/2 | v2-h1 / v1-h1 | v2-h2 / v1-h1 |")
    println(io, "|---|---|---:|---:|---:|---:|---:|")
    for endpoint in endpoints, c in concurrencies
        v1h1 = get(get(results, ("v1-h1",endpoint,c), Dict{String,Any}()), "req_s", NaN)
        v2h1 = get(get(results, ("v2-h1",endpoint,c), Dict{String,Any}()), "req_s", NaN)
        v2h2 = get(get(results, ("v2-h2",endpoint,c), Dict{String,Any}()), "req_s", NaN)
        delta_h1 = isnan(v1h1) || isnan(v2h1) ? "—" : @sprintf("%.2fx", v2h1/v1h1)
        delta_h2 = isnan(v1h1) || isnan(v2h2) ? "—" : @sprintf("%.2fx", v2h2/v1h1)
        @printf io "| %s | %d | %.0f | %.0f | %.0f | %s | %s |\n" endpoint c v1h1 v2h1 v2h2 delta_h1 delta_h2
    end

    println(io, "\n## Latency p50 (median, lower is better)\n")
    println(io, "| endpoint | conc | v1 HTTP/1.1 | v2 HTTP/1.1 | v2 HTTP/2 |")
    println(io, "|---|---|---:|---:|---:|")
    for endpoint in endpoints, c in concurrencies
        v1h1 = get(get(results, ("v1-h1",endpoint,c), Dict{String,Any}()), "lat_p50", NaN)
        v2h1 = get(get(results, ("v2-h1",endpoint,c), Dict{String,Any}()), "lat_p50", NaN)
        v2h2 = get(get(results, ("v2-h2",endpoint,c), Dict{String,Any}()), "lat_p50", NaN)
        @printf io "| %s | %d | %s | %s | %s |\n" endpoint c fmt_us(v1h1) fmt_us(v2h1) fmt_us(v2h2)
    end

    println(io, "\n## Latency p95 (lower is better)\n")
    println(io, "| endpoint | conc | v1 HTTP/1.1 | v2 HTTP/1.1 | v2 HTTP/2 |")
    println(io, "|---|---|---:|---:|---:|")
    for endpoint in endpoints, c in concurrencies
        v1h1 = get(get(results, ("v1-h1",endpoint,c), Dict{String,Any}()), "lat_p95", NaN)
        v2h1 = get(get(results, ("v2-h1",endpoint,c), Dict{String,Any}()), "lat_p95", NaN)
        v2h2 = get(get(results, ("v2-h2",endpoint,c), Dict{String,Any}()), "lat_p95", NaN)
        @printf io "| %s | %d | %s | %s | %s |\n" endpoint c fmt_us(v1h1) fmt_us(v2h1) fmt_us(v2h2)
    end

    println(io, "\n## Latency p99 (tail, lower is better)\n")
    println(io, "| endpoint | conc | v1 HTTP/1.1 | v2 HTTP/1.1 | v2 HTTP/2 |")
    println(io, "|---|---|---:|---:|---:|")
    for endpoint in endpoints, c in concurrencies
        v1h1 = get(get(results, ("v1-h1",endpoint,c), Dict{String,Any}()), "lat_p99", NaN)
        v2h1 = get(get(results, ("v2-h1",endpoint,c), Dict{String,Any}()), "lat_p99", NaN)
        v2h2 = get(get(results, ("v2-h2",endpoint,c), Dict{String,Any}()), "lat_p99", NaN)
        @printf io "| %s | %d | %s | %s | %s |\n" endpoint c fmt_us(v1h1) fmt_us(v2h1) fmt_us(v2h2)
    end

    # Errors / failures
    println(io, "\n## Failures (any failed/errored/timeout)\n")
    println(io, "| endpoint | conc | v1-h1 | v2-h1 | v2-h2 |")
    println(io, "|---|---|---|---|---|")
    for endpoint in endpoints, c in concurrencies
        function fail_str(label)
            d = get(results, (label,endpoint,c), nothing)
            d === nothing && return "—"
            f = get(d, "failed", 0); e = get(d, "errored", 0); t = get(d, "timeout", 0)
            return f == 0 && e == 0 && t == 0 ? "ok" : "F=$f E=$e T=$t"
        end
        @printf io "| %s | %d | %s | %s | %s |\n" endpoint c fail_str("v1-h1") fail_str("v2-h1") fail_str("v2-h2")
    end
end

println("wrote summary.csv and summary.md")
