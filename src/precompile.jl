function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    @assert precompile(HTTP.URIs.parseurlchar, (UInt8, Char, Bool,))
    @assert precompile(HTTP.status, (HTTP.Response,))
    @assert precompile(HTTP.Cookies.pathmatch, (HTTP.Cookies.Cookie, String,))
    @assert precompile(HTTP.onheaderfield, (HTTP.Parser, Array{UInt8, 1}, Int64, Int64,))
    @assert precompile(HTTP.isjson, (Array{UInt8, 1}, UInt64, Int64,))
    @assert precompile(HTTP.onheadervalue, (HTTP.Parser, HTTP.Response, Array{UInt8, 1}, Int64, Int64, Bool, String, Bool))
    @assert precompile(HTTP.isjson, (Array{UInt8, 1}, Int64, Int64,))
    @assert precompile(HTTP.onurlbytes, (HTTP.Parser, Array{UInt8, 1}, Int64, Int64,))
    @assert precompile(HTTP.onurl, (HTTP.Parser, HTTP.Response,))
    @assert precompile(HTTP.onurl, (HTTP.Parser, HTTP.Request,))
    @assert precompile(HTTP.Response, (Int64, String,))
    @assert precompile(HTTP.URIs.getindex, (Array{UInt8, 1}, HTTP.URIs.Offset,))
    @assert precompile(HTTP.iscompressed, (Array{UInt8, 1},))
    @assert precompile(HTTP.Cookies.readcookies, (Base.Dict{String, String}, String,))
    @assert precompile(HTTP.canonicalize!, (String,))
    @assert precompile(HTTP.URIs.http_parse_host_char, (HTTP.URIs.http_host_state, Char,))
    @assert precompile(HTTP.Form, (Base.Dict{String, Any},))
    @assert precompile(HTTP.Cookies.hasdotsuffix, (String, String,))
    @assert precompile(HTTP.onheadervalue, (HTTP.Parser, Array{UInt8, 1}, Int64, Int64,))
    @assert precompile(HTTP.Cookies.parsecookievalue, (String, Bool,))
    @assert precompile(HTTP.processresponse!, (HTTP.Client, HTTP.Connection{Base.TCPSocket}, HTTP.Response, String, HTTP.Method, Task, Bool, Float64, Bool, Bool))
    @assert precompile(HTTP.Request, (HTTP.Method, HTTP.URIs.URI, Base.Dict{String, String}, HTTP.FIFOBuffers.FIFOBuffer,))
    @assert precompile(HTTP.Cookies.isCookieDomainName, (String,))
    @assert precompile(HTTP.getbytes, (Base.TCPSocket, Float64))
    @assert precompile(HTTP.FIFOBuffers.write, (HTTP.FIFOBuffers.FIFOBuffer, Array{UInt8, 1}, Int64, Int64,))
    @assert precompile(HTTP.URIs.port, (HTTP.URIs.URI,))
    @assert precompile(HTTP.read, (HTTP.Form,))
    @assert precompile(HTTP.get, (HTTP.Nitrogen.ServerOptions, Symbol, Int64,))
    @assert precompile(HTTP.ignorewhitespace, (String, Int64, Int64,))
    @assert precompile(HTTP.Response, ())
    @assert precompile(HTTP.Cookies.string, (String, Array{HTTP.Cookies.Cookie, 1}, Bool,))
    @assert precompile(HTTP.FIFOBuffers.read, (HTTP.FIFOBuffers.FIFOBuffer, Int64,))
    @assert precompile(HTTP.processresponse!, (HTTP.Client, HTTP.Connection{MbedTLS.SSLContext}, HTTP.Response, String, HTTP.Method, Task, Bool, Float64, Bool, Bool))
    @assert precompile(HTTP.Form, (Base.Dict{String, String},))
    @assert precompile(HTTP.FIFOBuffers.String, (HTTP.FIFOBuffers.FIFOBuffer,))
    @assert precompile(HTTP.update!, (HTTP.RequestOptions, HTTP.RequestOptions,))
    @assert precompile(HTTP.restofstring, (String, Int64, Int64,))
    @assert precompile(HTTP.ismatch, (Type{HTTP.MP4Sig}, Array{UInt8, 1}, Int64,))
    @assert precompile(HTTP.connectandsend, (HTTP.Client, Type{HTTP.http}, String, String, HTTP.Request, HTTP.RequestOptions, Bool,))
    @assert precompile(HTTP.URIs.unescape, (String,))
    @assert precompile(HTTP.Request, ())
    @assert precompile(HTTP.isjson, (String, Int64, Int64,))
    @assert precompile(HTTP.URIs.splitpath, (String,))
    @assert precompile(HTTP.ignorewhitespace, (Array{UInt8, 1}, Int64, Int64,))
    @assert precompile(HTTP.Cookies.String, (HTTP.Cookies.Cookie, Bool,))
    @assert precompile(HTTP.Cookies.shouldsend, (HTTP.Cookies.Cookie, Bool, String, String,))
    @assert precompile(HTTP.Client, (Void, HTTP.RequestOptions,))
    @assert precompile(HTTP.Cookies.parsecookievalue, (Base.SubString{String}, Bool,))
    @assert precompile(HTTP.ignorewhitespace, (Array{UInt8, 1}, UInt64, Int64,))
    @assert precompile(HTTP.Cookies.hash, (HTTP.Cookies.Cookie, UInt,))
    @assert precompile(HTTP.ismatch, (HTTP.HTMLSig, Array{UInt8, 1}, Int64,))
    @assert precompile(HTTP.redirect, (HTTP.Response, HTTP.Client, HTTP.Request, HTTP.RequestOptions, Bool, Array{HTTP.Response, 1}, Int64, Bool,))
    @assert precompile(HTTP.get, (HTTP.RequestOptions, Symbol, Int64,))
    @assert precompile(HTTP.Cookies.isequal, (HTTP.Cookies.Cookie, HTTP.Cookies.Cookie,))
    @assert precompile(HTTP.sniff, (String,))
    @assert precompile(HTTP.restofstring, (Array{UInt8, 1}, UInt64, Int64,))
    @assert precompile(HTTP.stalebytes!, (Base.TCPSocket,))
    @assert precompile(HTTP.FIFOBuffers.write, (HTTP.FIFOBuffers.FIFOBuffer, UInt8,))
    @assert precompile(HTTP.eof, (HTTP.Form,))
    @assert precompile(HTTP.Cookies.readsetcookie, (String, String,))
    @assert precompile(HTTP.Response, (Int64, HTTP.Request,))
    @assert precompile(HTTP.URIs.http_parser_parse_url, (Array{UInt8, 1}, Int64, Int64, Bool,))
    @assert precompile(HTTP.Response, (String,))
    @assert precompile(HTTP.FIFOBuffers.read, (HTTP.FIFOBuffers.FIFOBuffer, Type{Tuple{UInt8, Bool}},))
    @assert precompile(HTTP.Response, (Int64, Base.Dict{String, String}, String,))
    @assert precompile(HTTP.ismatch, (HTTP.Masked, Array{UInt8, 1}, Int64,))
    @assert precompile(HTTP.Cookies.sanitizeCookieValue, (String,))
    @assert precompile(HTTP.URIs.escape, (Int64, Int64,))
    @assert precompile(HTTP.URIs.http_parse_host, (Array{UInt8, 1}, HTTP.URIs.Offset, Bool,))
    @assert precompile(HTTP.read, (HTTP.Form, Int64,))
    @assert precompile(HTTP.nb_available, (HTTP.Multipart{Base.IOStream},))
    @assert precompile(HTTP.URIs.host, (HTTP.URIs.URI,))
    @assert precompile(HTTP.Request, (HTTP.Method, HTTP.URIs.URI, Base.Dict{String, String}, HTTP.Form,))
    @assert precompile(HTTP.getbytes, (MbedTLS.SSLContext, Float64))
    @assert precompile(HTTP.ismatch, (HTTP.Exact, Array{UInt8, 1}, Int64,))
    @assert precompile(HTTP.getconnections, (Type{HTTP.https}, HTTP.Client, String,))
    @assert precompile(HTTP.ismatch, (Type{HTTP.TextSig}, Array{UInt8, 1}, Int64,))
    @assert precompile(HTTP.restofstring, (Array{UInt8, 1}, Int64, Int64,))
    @assert precompile(HTTP.dead!, (HTTP.Connection{Base.TCPSocket},))
    @assert precompile(HTTP.addcookies!, (HTTP.Client, String, HTTP.Request, Bool,))
    @assert precompile(HTTP.FIFOBuffers.length, (HTTP.FIFOBuffers.FIFOBuffer,))
    @assert precompile(HTTP.Cookies.domainandtype, (String, String,))
    @assert precompile(HTTP.sniff, (Array{UInt8, 1},))
    @assert precompile(HTTP.mark, (HTTP.Multipart{Base.IOStream},))
    @assert precompile(HTTP.seek, (HTTP.Form, Int64,))
    @assert precompile(HTTP.onheadervalue, (HTTP.Parser, HTTP.Request, Array{UInt8, 1}, Int64, Int64, Bool, String, Bool))
    @assert precompile(HTTP.FIFOBuffers.write, (HTTP.FIFOBuffers.FIFOBuffer, String,))
    @assert precompile(HTTP.URIs.escape, (String, String,))
    @assert precompile(HTTP.dead!, (HTTP.Connection{MbedTLS.SSLContext},))
    @assert precompile(HTTP.URIs.isvalid, (HTTP.URIs.URI,))
    @assert precompile(HTTP.FIFOBuffers.read, (HTTP.FIFOBuffers.FIFOBuffer, Type{UInt8},))
    @assert precompile(HTTP.getconnections, (Type{HTTP.http}, HTTP.Client, String,))
    @assert precompile(HTTP.Cookies.validCookieDomain, (String,))
    @assert precompile(HTTP.headers, (HTTP.Response,))
    @assert precompile(HTTP.request, (HTTP.Response,))
    @assert precompile(HTTP.URIs.escape, (String, Array{String, 1},))
    @assert precompile(HTTP.connectandsend, (HTTP.Client, Type{HTTP.https}, String, String, HTTP.Request, HTTP.RequestOptions, Bool,))
    @assert precompile(HTTP.body, (HTTP.Response,))
    @assert precompile(HTTP.http_should_keep_alive, (HTTP.Parser, HTTP.Request,))
    @assert precompile(HTTP.length, (HTTP.Form,))
    @assert precompile(HTTP.FIFOBuffers.position, (HTTP.FIFOBuffers.FIFOBuffer,))
    @assert precompile(HTTP.URIs.escape, (String,))
    @assert precompile(HTTP.busy!, (HTTP.Connection{Base.TCPSocket},))
    @assert precompile(HTTP.connect, (HTTP.Client, HTTP.http, String, String, HTTP.RequestOptions, Bool,))
    @assert precompile(HTTP.string, (HTTP.Request,))
    @assert precompile(HTTP.parse!, (HTTP.Request, HTTP.Parser, Array{UInt8, 1},))
    @assert precompile(HTTP.parse!, (HTTP.Request, HTTP.Parser, Array{UInt8, 1}, Int64, Bool, String, HTTP.Method, Int64, Int64, Int64, Task, Bool))
    @assert precompile(HTTP.parse!, (HTTP.Response, HTTP.Parser, Array{UInt8, 1}, Int64, Bool, String, HTTP.Method, Int64, Int64, Int64, Task, Bool))
    @assert precompile(HTTP.onbody, (HTTP.Request, Task, Array{UInt8, 1}, Int64, Int64,))
    @assert precompile(HTTP.take!, (HTTP.Response,))
    @assert precompile(HTTP.Response, (String,))
    @assert precompile(HTTP.Cookies.Cookie, (Base.SubString{String}, Base.SubString{String},))
    @assert precompile(HTTP.initTLS!, (Type{HTTP.http}, String, HTTP.RequestOptions, Base.TCPSocket,))
    @assert precompile(HTTP.cookies, (HTTP.Response,))
    @assert precompile(HTTP.history, (HTTP.Response,))
    @assert precompile(HTTP.setconnection!, (Type{HTTP.https}, HTTP.Client, String, HTTP.Connection{MbedTLS.SSLContext},))
    @assert precompile(HTTP.setconnection!, (Type{HTTP.http}, HTTP.Client, String, HTTP.Connection{Base.TCPSocket},))
    @assert precompile(HTTP.eof, (HTTP.Multipart{Base.IOStream},))
    @assert precompile(HTTP.position, (HTTP.Form,))
    @assert precompile(HTTP.haskey, (Type{HTTP.http}, HTTP.Client, String,))
    @assert precompile(HTTP.parse!, (HTTP.Response, HTTP.Parser, Array{UInt8, 1},))
    @assert precompile(HTTP.reset, (HTTP.Multipart{Base.IOStream},))
    @assert precompile(HTTP.FIFOBuffers.seek, (HTTP.FIFOBuffers.FIFOBuffer, Tuple{Int64, Int64, Int64},))
    @assert precompile(HTTP.FIFOBuffers.wait, (HTTP.FIFOBuffers.FIFOBuffer,))
    @assert precompile(HTTP.initTLS!, (Type{HTTP.https}, String, HTTP.RequestOptions, Base.TCPSocket,))
    @assert precompile(HTTP.stalebytes!, (MbedTLS.SSLContext,))
    @assert precompile(HTTP.sniff, (Base.IOStream,))
    @assert precompile(HTTP.request, (HTTP.Client, HTTP.Request, HTTP.RequestOptions, Bool, Array{HTTP.Response, 1}, Int, Bool,))
    @assert precompile(HTTP.read, (HTTP.Multipart{Base.IOStream}, Int64,))
    @assert precompile(HTTP.isjson, (Array{UInt8, 1},))
    @assert precompile(HTTP.FIFOBuffers.close, (HTTP.FIFOBuffers.FIFOBuffer,))
    @assert precompile(HTTP.headers, (HTTP.Request,))
    @assert precompile(HTTP.busy!, (HTTP.Connection{MbedTLS.SSLContext},))
    @assert precompile(HTTP.seek, (HTTP.Form, Tuple{Int64, Int64, Int64},))
    @assert precompile(HTTP.FIFOBuffers.eof, (HTTP.FIFOBuffers.FIFOBuffer,))
    @assert precompile(HTTP.contenttype, (HTTP.Masked,))
    @assert precompile(HTTP.get, (HTTP.RequestOptions, Symbol, MbedTLS.SSLConfig,))
    @assert precompile(HTTP.contenttype, (HTTP.Exact,))
    @assert precompile(HTTP.FIFOBuffers.FIFOBuffer, (HTTP.FIFOBuffers.FIFOBuffer,))
    @assert precompile(HTTP.haskey, (Type{HTTP.https}, HTTP.Client, String,))
    @assert precompile(HTTP.FIFOBuffers.readavailable, (HTTP.FIFOBuffers.FIFOBuffer,))
    @assert precompile(HTTP.string, (HTTP.Response, HTTP.Nitrogen.ServerOptions,))
    @assert precompile(HTTP.string, (HTTP.Response, HTTP.RequestOptions,))
    @assert precompile(HTTP.string, (HTTP.Request, HTTP.RequestOptions,))
    @assert precompile(HTTP.Request, (String,))
    @assert precompile(HTTP.ismatch, (Type{HTTP.JSONSig}, Array{UInt8, 1}, Int64,))
    @assert precompile(HTTP.hasmessagebody, (HTTP.Request,))
    @assert precompile(HTTP.FIFOBuffers.write, (HTTP.FIFOBuffers.FIFOBuffer, Array{UInt8, 1},))
    @assert precompile(HTTP.readavailable, (HTTP.Form,))
    @assert precompile(HTTP.get, (String,))
    @assert precompile(HTTP.URL, (String,))
    @assert precompile(HTTP.request, (HTTP.Client, HTTP.Method, HTTP.URI,))
    @assert precompile(HTTP.RequestOptions, ())
    @assert precompile(HTTP.Request, (HTTP.Method, HTTP.URI, Dict{String, String}, HTTP.FIFOBuffer))
    @assert precompile(HTTP.request, (HTTP.Request,))
    @assert precompile(HTTP.request, (HTTP.Client, HTTP.Request))
    @assert precompile(HTTP.request, (HTTP.Client, HTTP.Request, HTTP.RequestOptions, Bool, Vector{HTTP.Response}, Int, Bool))
    @static if VERSION < v"0.7-DEV"
        @assert precompile(HTTP.Client, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.RequestOptions,))
        @assert precompile(HTTP.URIs.printuri, (Base.AbstractIOBuffer{Array{UInt8, 1}}, String, String, String, String, String, String, String,))
        @assert precompile(HTTP.FIFOBuffers.FIFOBuffer, (Base.AbstractIOBuffer{Array{UInt8, 1}},))
        @assert precompile(HTTP.startline, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.Response,))
        @assert precompile(HTTP.writemultipartheader, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.Multipart{Base.IOStream},))
        @assert precompile(HTTP.print, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.Method,))
        @assert precompile(HTTP.sniff, (Base.AbstractIOBuffer{Array{UInt8, 1}},))
        @assert precompile(HTTP.headers, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.Response,))
        @assert precompile(HTTP.headers, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.Request,))
        @assert precompile(HTTP.body, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.Response, HTTP.Nitrogen.ServerOptions,))
        @assert precompile(HTTP.body, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.Response, HTTP.RequestOptions,))
        @assert precompile(HTTP.URIs.print, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.URIs.ParsingStateCode,))
        @assert precompile(HTTP.URIs.print, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.URIs.http_host_state,))
        @assert precompile(HTTP.showcompact, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.Request,))
        @assert precompile(HTTP.URIs.show, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.URIs.URI,))
        @assert precompile(HTTP.writemultipartheader, (Base.AbstractIOBuffer{Array{UInt8, 1}}, Base.IOStream,))
        @assert precompile(HTTP.URIs.print, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.URIs.URI,))
        @assert precompile(HTTP.body, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.Request, HTTP.RequestOptions,)) 
        @assert precompile(HTTP.startline, (Base.AbstractIOBuffer{Array{UInt8, 1}}, HTTP.Request,))
    else
        @assert precompile(HTTP.Client, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.RequestOptions,))
        @assert precompile(HTTP.URIs.printuri, (Base.GenericIOBuffer{Array{UInt8, 1}}, String, String, String, String, String, String, String,))
        @assert precompile(HTTP.FIFOBuffers.FIFOBuffer, (Base.GenericIOBuffer{Array{UInt8, 1}},))
        @assert precompile(HTTP.startline, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Response,))
        @assert precompile(HTTP.writemultipartheader, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Multipart{Base.IOStream},))
        @assert precompile(HTTP.print, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Method,))
        @assert precompile(HTTP.sniff, (Base.GenericIOBuffer{Array{UInt8, 1}},))
        @assert precompile(HTTP.headers, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Response,))
        @assert precompile(HTTP.headers, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Request,))
        @assert precompile(HTTP.body, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Response, HTTP.Nitrogen.ServerOptions,))
        @assert precompile(HTTP.body, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Response, HTTP.RequestOptions,))
        @assert precompile(HTTP.URIs.print, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.URIs.ParsingStateCode,))
        @assert precompile(HTTP.URIs.print, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.URIs.http_host_state,))
        @assert precompile(HTTP.showcompact, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Request,))
        @assert precompile(HTTP.URIs.show, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.URIs.URI,))
        @assert precompile(HTTP.writemultipartheader, (Base.GenericIOBuffer{Array{UInt8, 1}}, Base.IOStream,))
        @assert precompile(HTTP.URIs.print, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.URIs.URI,))
        @assert precompile(HTTP.body, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Request, HTTP.RequestOptions,))
        @assert precompile(HTTP.startline, (Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Request,))
    end
end
_precompile_()
