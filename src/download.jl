using .Pairs
using CodecZlib

"""
    safer_joinpath(basepart, parts...)
A variation on `joinpath`, that is more resistant to directory traversal attacks.
The parts to be joined (excluding the `basepart`),
are not allowed to contain `..`, or begin with a `/`.
If they do then this throws an `DomainError`.
"""
function safer_joinpath(basepart, parts...)
    explain =  "Possible directory traversal attack detected."
    for part in parts
        occursin("..", part) && throw(DomainError(part, "contains \"..\". $explain"))
        startswith(part, '/') && throw(DomainError(part, "begins with \"/\". $explain"))
    end
    joinpath(basepart, parts...)
end

function try_get_filename_from_headers(hdrs)
    for content_disp in hdrs
        # extract out of Content-Disposition line
        # rough version of what is needed in https://github.com/JuliaWeb/HTTP.jl/issues/179
        filename_part = match(r"filename\s*=\s*(.*)", content_disp)
        if filename_part !== nothing
            filename = filename_part[1]
            quoted_filename = match(r"\"(.*)\"", filename)
            if quoted_filename !== nothing
                # It was in quotes, so it will be double escaped
                filename = unescape_string(quoted_filename[1])
            end
            return filename == "" ? nothing : filename
        end
    end
    return nothing
end

function try_get_filename_from_request(req)
    function file_from_target(t)
        (t == "" || t == "/") && return nothing
        f = basename(URI(t).path) # URI(...).path to strip out e.g. query parts
        return (f == "" ? file_from_target(dirname(t)) : f)
    end

    # First try to get file from the original request URI
    oreq = req
    while oreq.parent !== nothing
        oreq = oreq.parent.request
    end
    f = file_from_target(oreq.target)
    f !== nothing && return f

    # Secondly try to get file from the last request URI
    return file_from_target(req.target)
end


determine_file(::Nothing, resp, hdrs) = determine_file(tempdir(), resp, hdrs)
# ^ We want to the filename if possible because extension is useful for FileIO.jl

function determine_file(path, resp, hdrs)
    if isdir(path)
        # we have been given a path to a directory
        # got to to workout what file to put there
        filename = something(
                        try_get_filename_from_headers(hdrs),
                        try_get_filename_from_request(resp.request),
                        basename(tempname())  # fallback, basically a random string
                    )

        
        safer_joinpath(path, filename)
    else
        # We have been given a full filepath
        path
    end
end

"""
    download(url, [local_path], [headers]; update_period=1, kw...)

Similar to `Base.download` this downloads a file, returning the filename.
If the `local_path`:
 - is not provided, then it is saved in a temporary directory
 - if part to a directory is provided then it is saved into that directory
 - otherwise the local path is uses as the filename to save to.

When saving into a directory, the filename is determined (where possible),
from the rules of the HTTP.

 - `update_period` controls how often (in seconds) to report the progress.
    - set to `Inf` to disable reporting
 - `headers` specifies headers to be used for the HTTP GET request
 - any additional keyword args (`kw...`) are passed on to the HTTP request.
"""
function download(url::AbstractString, local_path=nothing, headers=Header[]; update_period=1, kw...)
    format_progress(x) = round(x, digits=4)
    format_bytes(x) = !isfinite(x) ? "∞ B" : Base.format_bytes(round(Int, x))
    format_seconds(x) = "$(round(x; digits=2)) s"
    format_bytes_per_second(x) = format_bytes(x) * "/s"


    @debugv 1 "downloading $url"
    local file
    hdrs = String[]
    HTTP.open("GET", url, headers; kw...) do stream
        resp = startread(stream)
        # Store intermediate header from redirects to use for filename detection
        content_disp = header(resp, "Content-Disposition")
        !isempty(content_disp) && push!(hdrs, content_disp)
        eof(stream) && return  # don't do anything for streams we can't read (yet)

        file = determine_file(local_path, resp, hdrs)
        total_bytes = parse(Float64, header(resp, "Content-Length", "NaN"))
        downloaded_bytes = 0
        start_time = now()
        prev_time = now()

        if header(resp, "Content-Encoding") == "gzip"
            stream = GzipDecompressorStream(stream) # auto decoding
            total_bytes = NaN # We don't know actual total bytes if the content is zipped.
        end

        function report_callback()
            prev_time = now()
            taken_time = (prev_time - start_time).value / 1000 # in seconds
            average_speed = downloaded_bytes / taken_time
            remaining_bytes = total_bytes - downloaded_bytes
            remaining_time = remaining_bytes / average_speed
            completion_progress = downloaded_bytes / total_bytes

            @info("Downloading",
                  source=url,
                  dest = file,
                  progress = completion_progress |> format_progress,
                  time_taken = taken_time |> format_seconds,
                  time_remaining = remaining_time |> format_seconds,
                  average_speed = average_speed |> format_bytes_per_second,
                  downloaded = downloaded_bytes |> format_bytes,
                  remaining = remaining_bytes |> format_bytes,
                  total = total_bytes |> format_bytes,
                 )
        end

        Base.open(file, "w") do fh
            while(!eof(stream))
                downloaded_bytes += write(fh, readavailable(stream))
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
    file
end
