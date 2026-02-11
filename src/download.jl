function safer_joinpath(basepart, parts...)
    explain = "Possible directory traversal attack detected."
    for part in parts
        occursin("..", part) && throw(DomainError(part, "contains \"..\". $explain"))
        startswith(part, '/') && throw(DomainError(part, "begins with \"/\". $explain"))
    end
    return joinpath(basepart, parts...)
end

function try_get_filename_from_headers(hdrs)
    for content_disp in hdrs
        filename_part = match(r"filename\\s*=\\s*(.*)", content_disp)
        if filename_part !== nothing
            filename = filename_part[1]
            quoted_filename = match(r"\\\"(.*)\\\"", filename)
            if quoted_filename !== nothing
                filename = unescape_string(quoted_filename[1])
            end
            return filename == "" ? nothing : filename
        end
    end
    return nothing
end

function try_get_filename_from_request(req::Request)
    function file_from_target(t)
        (t == "" || t == "/") && return nothing
        f = basename(URI(t).path)
        return f == "" ? file_from_target(dirname(t)) : f
    end
    return file_from_target(req.path)
end

determine_file(::Nothing, resp, hdrs) = determine_file(tempdir(), resp, hdrs)

function determine_file(path, resp, hdrs)
    if isdir(path)
        filename = something(
            try_get_filename_from_headers(hdrs),
            resp.request === nothing ? nothing : try_get_filename_from_request(resp.request),
            basename(tempname(; cleanup = false))
        )
        return safer_joinpath(path, filename)
    end
    return path
end

"""
    download(url, [local_path], [headers]; update_period=1, kw...)

Download a URL to a local file, returning the filename. If `local_path` is not
provided, the file is saved in a temporary directory. If `local_path` is a
directory, the filename is determined from response headers or request target.

`update_period` controls progress reporting in seconds (set to `Inf` to disable).
Additional keyword arguments are forwarded to `HTTP.open`.
"""
function download(url::AbstractString, local_path=nothing, headers=Header[]; update_period=1, kw...)
    format_progress(x) = round(x, digits=4)
    format_bytes(x) = !isfinite(x) ? "∞ B" : Base.format_bytes(round(Int, max(x, 0)))
    format_seconds(x) = "$(round(x; digits=2)) s"
    format_bytes_per_second(x) = format_bytes(x) * "/s"

    @debug "downloading $url"
    local file
    hdrs = String[]
    HTTP.open("GET", url, headers; kw...) do stream
        resp = startread(stream)
        content_disp = header(resp, "Content-Disposition")
        !isempty(content_disp) && push!(hdrs, content_disp)
        eof(stream) && return

        file = determine_file(local_path, resp, hdrs)
        total_bytes = parse(Float64, header(resp, "Content-Length", "NaN"))
        downloaded_bytes = 0
        start_time = now()
        prev_time = now()

        if header(resp, "Content-Encoding") == "gzip"
            total_bytes = NaN
        end

        function report_callback()
            prev_time = now()
            taken_time = (prev_time - start_time).value / 1000
            average_speed = taken_time > 0 ? downloaded_bytes / taken_time : NaN
            remaining_bytes = total_bytes - downloaded_bytes
            remaining_bytes = isfinite(remaining_bytes) && remaining_bytes < 0 ? 0 : remaining_bytes
            remaining_time = average_speed > 0 ? remaining_bytes / average_speed : NaN
            completion_progress = isfinite(total_bytes) && total_bytes > 0 ? downloaded_bytes / total_bytes : NaN
            completion_progress = isfinite(completion_progress) ? clamp(completion_progress, 0, 1) : completion_progress
            @info("Downloading",
                  source=url,
                  dest=file,
                  progress=completion_progress |> format_progress,
                  time_taken=taken_time |> format_seconds,
                  time_remaining=remaining_time |> format_seconds,
                  average_speed=average_speed |> format_bytes_per_second,
                  downloaded=downloaded_bytes |> format_bytes,
                  remaining=remaining_bytes |> format_bytes,
                  total=total_bytes |> format_bytes,
                 )
        end

        Base.open(file, "w") do io
            while !eof(stream)
                buf = readavailable(stream)
                wrote = write(io, buf)
                downloaded_bytes += wrote
                if !isinf(update_period)
                    if now() - prev_time > Millisecond(round(1000update_period))
                        report_callback()
                    end
                end
            end
        end
        if !isinf(update_period)
            report_callback()
        end
    end
    return file
end
