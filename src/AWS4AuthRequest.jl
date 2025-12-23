module AWS4AuthRequest

if VERSION > v"0.7.0-DEV.2338"
using Base64
end

using Dates
using Unicode
using MbedTLS: digest, MD_SHA256, MD_MD5
import ..Layer, ..request, ..Headers
using ..URIs
using ..Pairs: getkv, setkv, rmkv
import ..@debug, ..DEBUG_LEVEL


"""
    request(AWS4AuthLayer, ::URI, ::Request, body) -> HTTP.Response

Add a [AWS Signature Version 4](http://docs.aws.amazon.com/general/latest/gr/signature-version-4.html)
`Authorization` header to a `Request`.


Credentials are read from environment variables `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN`.
"""

abstract type AWS4AuthLayer{Next <: Layer} <: Layer end
export AWS4AuthLayer

function request(::Type{AWS4AuthLayer{Next}},
                 uri::URI, req, body; kw...) where Next

    if !haskey(kw, :aws_access_key_id) &&
       !haskey(ENV, "AWS_ACCESS_KEY_ID")
        kw = merge(dot_aws_credentials(), kw)
    end

    sign_aws4!(req.method, uri, req.headers, req.body; kw...)

    return request(Next, uri, req, body; kw...)
end


ispathsafe(c::Char) = c == '/' || URIs.issafe(c)
escape_path(path) = escapeuri(path, ispathsafe)


function sign_aws4!(method::String,
                    uri::URI,
                    headers::Headers,
                    body::Vector{UInt8};
                    body_sha256::Vector{UInt8}=digest(MD_SHA256, body),
                    body_md5::Vector{UInt8}=digest(MD_MD5, body),
                    t::DateTime=now(Dates.UTC),
                    aws_service::String=String(split(uri.host, ".")[1]),
                    aws_region::String=String(split(uri.host, ".")[2]),
                    aws_access_key_id::String=ENV["AWS_ACCESS_KEY_ID"],
                    aws_secret_access_key::String=ENV["AWS_SECRET_ACCESS_KEY"],
                    aws_session_token::String=get(ENV, "AWS_SESSION_TOKEN", ""),
                    kw...)


    # ISO8601 date/time strings for time of request...
    date = Dates.format(t,"yyyymmdd")
    datetime = Dates.format(t,"yyyymmddTHHMMSSZ")

    # Authentication scope...
    scope = [date, aws_region, aws_service, "aws4_request"]

    # Signing key generated from today's scope string...
    signing_key = string("AWS4", aws_secret_access_key)
    for element in scope
        signing_key = digest(MD_SHA256, element, signing_key)
    end

    # Authentication scope string...
    scope = join(scope, "/")

    # SHA256 hash of content...
    content_hash = bytes2hex(body_sha256)

    # HTTP headers...
    rmkv(headers, "Authorization")
    setkv(headers, "x-amz-content-sha256",  content_hash)
    setkv(headers, "x-amz-date",  datetime)
    setkv(headers, "Content-MD5", base64encode(body_md5))
    if aws_session_token != ""
        setkv(headers, "x-amz-security-token", aws_session_token)
    end

    # Sort and lowercase() Headers to produce canonical form...
    canonical_headers = ["$(lowercase(k)):$(strip(v))" for (k,v) in headers]
    signed_headers = join(sort([lowercase(k) for (k,v) in headers]), ";")

    # Sort Query String...
    query = queryparams(uri.query)
    query = Pair[k => query[k] for k in sort(collect(keys(query)))]

    # Create hash of canonical request...
    canonical_form = string(method, "\n",
                            aws_service == "s3" ? uri.path
                                                : escape_path(uri.path), "\n",
                            escapeuri(query), "\n",
                            join(sort(canonical_headers), "\n"), "\n\n",
                            signed_headers, "\n",
                            content_hash)
    @debug 3 "AWS4 canonical_form: $canonical_form"

    canonical_hash = bytes2hex(digest(MD_SHA256, canonical_form))

    # Create and sign "String to Sign"...
    string_to_sign = "AWS4-HMAC-SHA256\n$datetime\n$scope\n$canonical_hash"
    signature = bytes2hex(digest(MD_SHA256, string_to_sign, signing_key))

    @debug 3 "AWS4 string_to_sign: $string_to_sign"
    @debug 3 "AWS4 signature: $signature"

    # Append Authorization header...
    setkv(headers, "Authorization", string(
        "AWS4-HMAC-SHA256 ",
        "Credential=$aws_access_key_id/$scope, ",
        "SignedHeaders=$signed_headers, ",
        "Signature=$signature"
    ))
end


using IniFile

credentials = NamedTuple()

"""
Load Credentials from [AWS CLI ~/.aws/credentials file]
(http://docs.aws.amazon.com/cli/latest/userguide/cli-config-files.html).
"""

function dot_aws_credentials()::NamedTuple

    global credentials
    if !isempty(credentials)
        return credentials
    end

    f = get(ENV, "AWS_CONFIG_FILE", joinpath(homedir(), ".aws", "credentials"))
    p = get(ENV, "AWS_DEFAULT_PROFILE", get(ENV, "AWS_PROFILE", "default"))

    if !isfile(f)
        return NamedTuple()
    end

    ini = read(Inifile(), f)

    credentials = (
        aws_access_key_id = String(get(ini, p, "aws_access_key_id")),
        aws_secret_access_key = String(get(ini, p, "aws_secret_access_key")))
end


end # module BasicAuthRequest
