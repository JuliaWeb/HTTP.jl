
#
# Chunked Data Transfer
#

immutable ChunkedStream
    io::IO
end
function write_chunked(stream, arg)
    write(stream,string(hex(sizeof(arg)),CRLF))
    write(stream,arg)
    write(stream,string(CRLF))
end

write(io::ChunkedStream, arg) = write_chunked(io.io, arg)

#
# File uploads
#
# Upload a file using multipart form upload. `file` may be one of:
#
#   - An IO object whose contents will be uploaded
#   - A string or Array to be sent
#
# Note that when passing an IO object, the IO object may not otherwise be modified
# until the request completes. Optionally you may set `close` to true to have Requests
# automatically close your file when it's done with it.
#

immutable FileParam
    file::Union{IO,Base.File,AbstractString,Vector{UInt8}}     # The file
    # The content type (default: "", which is interpreted as text/plain serverside)
    ContentType::Compat.UTF8String
    name::Compat.UTF8String                     # The fieldname (in a form)
    filename::Compat.UTF8String                              # The filename (of the actual file)
    # Whether or not to close the file when the request is done
    close::Bool

    function FileParam(str::Union{AbstractString,Vector{UInt8}},ContentType="",name="",filename="")
        new(str,ContentType,name,filename,false)
    end

    function FileParam(io::IO,ContentType="",name="",filename="",close::Bool=false)
        new(io,ContentType,name,filename,close)
    end

    function FileParam(io::Base.File,ContentType="",name="",filename="",close::Bool=false)
        if !isopen(io)
            close = true
        end
        new(io,ContentType,name,filename,close)
    end
end

# Determine whether or not we need to use
datasize(::IO) = -1
datasize(f::Union{AbstractString,Array{UInt8}}) = sizeof(f)
datasize(f::File) = filesize(f)
datasize(f::IOBuffer) = nb_available(f)
function datasize(io::IOStream)
    iofd = fd(io)
    # If this IOStream is not backed by a file, we can't find the filesize
    if iofd == -1
        return -1
    else
        return filesize(iofd) - position(io)
    end
end

const multipart_mime = "multipart/form-data; boundary="
const part_mime = "Content-Disposition: form-data"
const name_file = "; name=\""
const filename_file = "; filename=\""
const ContentType_header = "Content-Type: "

function write_part_header(stream,file::FileParam,boundary)
    buf = IOBuffer()
    write(buf,"--",boundary,CRLF)
    write(buf,part_mime)
    !isempty(file.name) && write(buf,name_file,file.name,'\"')
    !isempty(file.filename) && write(buf,filename_file,file.filename,'\"')
    write(buf,CRLF)
    !isempty(file.ContentType) && write(buf,ContentType_header,file.ContentType,CRLF)
    write(buf,CRLF)
    write(stream,takebuf_array(buf))
end

# Write a file by reading it in 1MB chunks (unless we know its size and it's smaller than that)
function write_file(stream,file::IO,datasize,doclose)
    datasize == datasize == -1 : 2^20 : min(2^20,datasize)
    x = Array(UInt8,datasize)
    while !eof(file)
        nread = readbytes!(file,x)
        if nread == 2^20
            write(stream,x)
        else
            write(stream,sub(x,1:nread))
        end
    end
    doclose && close(file)
end

# Write a file by mmaping it
function write_file(stream,file::IOStream,datasize,doclose)
    @assert datasize != -1
    write(stream, Mmap.mmap(file, Vector{UInt8}, datasize, position(file)))
    doclose && close(file)
end

# Write data already in memory
function write_file(stream,file::Union{AbstractString,Array{UInt8}},datasize,doclose)
    @assert datasize != -1
    write(stream,file)
    doclose && close(file)
end

function write_file(stream,file::IOBuffer,datasize,doclose)
    @assert datasize != -1
    write(stream,sub(file.data,(position(file)+1):(position(file)+nb_available(file))))
    doclose && close(file)
end

function partheadersize(file,datasize,boundary)
    totalsize = 0
    # Chucksize =
    #   +  "--" (2) + boundary (sizeof(boundary)) + "\r\n" (2)
    totalsize += (2 + sizeof(boundary) ) + 2
    #   + multipart_mime + optional names + "\r\n"(2)
    totalsize += sizeof(multipart_mime)
    if !isempty(file.name)
        # +1 for "\""
        totalsize += sizeof(name_file) + sizeof(file.name) + 1
    end
    if !isempty(file.filename)
        # +1 for "\""
        totalsize += sizeof(filename_file) + sizeof(file.filename) + 1
    end
    totalsize += 2
    if !isempty(file.ContentType)
        # +2 for "\r\n"
        totalsize += sizeof(ContentType_header) + sizeof(file.ContentType) + 2
    end
    # "\r\n" + The actual data + "\r\n" (2)
    totalsize += 2 + datasize + 2
    totalsize
end

choose_boundary() = hex(rand(UInt128))

function send_multipart(stream, settings, files)
    chunked, boundary, datasizes = settings.chunked, settings.boundary, settings.datasizes
    if chunked
        begin
            for i = 1:length(files)
                file = files[i]
                if datasizes[i] != -1
                    # Make this all one chunk
                    #write(stream,hex(datasizes[i]+partheadersize(file,0,boundary)),CRLF)
                    write_part_header(ChunkedStream(stream),file, boundary)
                    write_file(ChunkedStream(stream),file.file,datasizes[i],file.close)
                    # File CRLF
                    write(ChunkedStream(stream),CRLF)
                    # Chunk CRLF
                    #write(stream,CRLF)
                else
                    phs = partheadersize(file,0,boundary)-2
                    # Make the part header one chunk
                    write(stream,hex(phs),CRLF)
                    write_part_header(stream,file, boundary)
                    # Chunk CRLF
                    write(stream,CRLF)
                    # Write the rest as a chunk
                    write_file(ChunkedStream(stream),file.file,datasizes[i],file.close)
                    # This sucks, I'm making and extra chunk just for CRLF, but
                    # so be it for now
                    write(stream,"1\r\n\r\n\r\n")
                end
            end
            write(ChunkedStream(stream),"--$boundary--")
            write(stream,string(hex(0),CRLF,CRLF))
        end
    else
        begin
            for i = 1:length(files)
                file = files[i]
                write_part_header(stream,file, boundary)
                write_file(stream,file.file,datasizes[i],file.close)
                write(stream,CRLF)
            end
            write(stream, "--$boundary--", CRLF)
        end
    end

end

immutable MultipartSettings
    datasizes::Vector{Int}
    boundary::Compat.UTF8String
    chunked::Bool
end

function prepare_multipart_request!(request, files)
    local boundary
    headers = request.headers
    if !haskey(headers,"Content-Type")
        boundary = choose_boundary()
        headers["Content-Type"] = multipart_mime*boundary
    else

        if headers["Content-Type"][1:sizeof(multipart_mime)] != multipart_mime
            error("Cannot extract boundary from MIME type")
        end
        boundary = headers["Content-Type"][(sizeof(multipart_mime)+1):end]
    end

    chunked = false
    if haskey(headers,"Transfer-Encoding")
        if headers["Transfer-Encoding"] != "chunked"
            error("Unrecognized Transfer-Encoding")
        end
        chunked = true
    end

    datasizes = Array(Int,length(files))

    # Try to determine final size of the request. If this fails,
    # we fall back to chunked transfer
    totalsize = 0
    for i = 1:length(files)
        file = files[i]
        size = datasizes[i] = datasize(file.file)
        if size == -1
            if !chunked
                error("""Tried to pass in an IO object that is not of fixed size.\n
                         This is only support with the chunked Transfer-Encoding.\n
                         Please verify however that the server you are connecting to\n
                         supports chunked transfer encoding as support for this feature\n
                         is broken in a large number of servers.\n""")
            end
            # don't break because we'll still use the datasize later if
            # available to optimize chunked transfer
        end
        totalsize += partheadersize(file,size,boundary)
    end
    # "--" (2) + boundary (sizeof(boundary)) + "--" (2) + CRLF (2)
    totalsize += 2 + sizeof(boundary) + 2 + 2


    if chunked
        headers["Transfer-Encoding"] = "chunked"
    else
        headers["Content-Length"] = dec(totalsize)
    end

    MultipartSettings(datasizes, boundary, chunked)
end

function send_multipart(uri, headers, files, verb, timeout, tls_conf)
    req, datasizes, boundary, chunked = prepare_multipart_send(uri,headers,files,verb)
    stream = open_stream(uri,req,tls_conf)
    do_multipart_send(stream,files,datasizes, boundary, chunked)
    process_response(stream, timeout), req
end
