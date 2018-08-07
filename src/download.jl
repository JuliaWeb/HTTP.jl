using .Pairs

"""
    safer_joinpath(basepart, parts...)
A variation on `joinpath`, that is more resistant to directory traveral attack
The parts to be joined (excluding the `basepart`),
are not allowed to contain `..`, or begin with a `/`.
If they do then this throws an `DomainError`.
"""
function safer_joinpath(basepart, parts...)
    explain =  "Possible Directory Traversal Attack detected."
    for part in parts
        contains(part, "..") && throw(DomainError(part, "contains illegal string \"..\". $explain"))
        startswith(part, '/') && throw(DomainError(part, "begins with \"/\". $explain"))
    end
    joinpath(basepart, parts...)
end

function try_get_filename_from_headers(headers)
    content_disp = getkv(headers, "Content-Disposition")
    if content_disp != nothing
        # extract out of Content-Disposition line
        # rough version of what is needed in https://github.com/JuliaWeb/HTTP.jl/issues/179
        filename_part = match(r"filename\s*=\s*(.*)", content_disp)
        if filename_part != nothing
            filename = filename_part[1]
            quoted_filename = match(r"\"(.*)\"", filename)
            if quoted_filename != nothing
                # It was in quotes, so it will be double escaped
                filename = unescape_string(quoted_filename[1])
            end
            return filename
        end
    end
    return nothing
end

function try_get_filename_from_remote_path(target)
    target == "" && return nothing
    filename = basename(target)
    if filename == ""
        try_get_filename_from_remote_path(dirname(target))
    else
        filename
    end
end


determine_file(::Nothing, resp) = determine_file(tempdir(), resp)
# ^ We want to the filename if possible because extension is useful for FileIO.jl

function determine_file(path, resp)
    # get the name
    name = if isdir(path)
        # got to to workout what file to put there
        filename = something(
                        try_get_filename_from_headers(resp.headers),
                        try_get_filename_from_remote_path(resp.request.target),
                        basename(tempname()) # fallback, basically a random string
                    )
        safer_joinpath(path, filename)
    else
        # It is a file, we are done.
        path
    end

    # get the extension, if we are going to save it in encoded form.
    if header(resp, "Content-Encoding") == "gzip"
        name *= ".gz"
    end
    name
end

"""
    download(url, [local_path], [headers]; update_period=0.5, kw...)

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
function download(url::AbstractString, local_path=nothing, headers=Header[]; update_period=0.5; kw...)
    @debug 1 "downloading $url"
    local file
    HTTP.open("GET", url, headers; kw..) do stream
        resp = startread(stream)
        file = determine_file(local_path, resp)
        total_bytes = parse(Float64, getkv(resp.headers, "Content-Length", "NaN"))
        downloaded_bytes = 0
        start_time = now()
        prev_time = now()

        function report_callback()
            prev_time = now()
            taken_time = (prev_time - start_time).value / 1000 # in seconds
            average_speed = downloaded_bytes / taken_time
            remaining_bytes = total_bytes - downloaded_bytes
            remaining_time = remaining_bytes/average_speed
            completion_progress = downloaded_bytes/total_bytes
        
            @info("Downloading",
                  source=url,
                  dest = file,
                  progress = completion_progress,
                  taken_time,
                  remaining_time,
                  average_speed,
                  downloaded_bytes,
                  remaining_bytes,
                  total_bytes,
            )
        end

        Base.open(file, "w") do fh
            while(!eof(stream))
                downloaded_bytes += write(fh, readavailable(stream))
                if now() - prev_time > Millisecond(1000update_period)
                    report_callback()
                end
            end
        end
        report_callback()
    end
    file
end
