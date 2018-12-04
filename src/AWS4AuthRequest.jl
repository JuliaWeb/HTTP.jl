module AWS4AuthRequest

using ..Base64
using ..Dates
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
                 url::URI, req, body; kw...) where Next

    if !haskey(kw, :aws_access_key_id) &&
       !haskey(ENV, "AWS_ACCESS_KEY_ID")
        kw = merge(dot_aws_credentials(), kw)
    end

    sign_aws4!(req.method, url, req.headers, req.body; kw...)

    return request(Next, url, req, body; kw...)
end

function sign_aws4!(method::String,
                    url::URI,
                    headers::Headers,
                    body::Vector{UInt8};
                    body_sha256::Vector{UInt8}=digest(MD_SHA256, body),
                    body_md5::Vector{UInt8}=digest(MD_MD5, body),
                    t::Union{DateTime,Nothing}=nothing,
                    timestamp::DateTime=now(Dates.UTC),
                    aws_service::String=String(split(url.host, ".")[1]),
                    aws_region::String=String(split(url.host, ".")[2]),
                    aws_access_key_id::String=ENV["AWS_ACCESS_KEY_ID"],
                    aws_secret_access_key::String=ENV["AWS_SECRET_ACCESS_KEY"],
                    aws_session_token::String=get(ENV, "AWS_SESSION_TOKEN", ""),
                    include_md5=true,
                    include_sha256=true,
                    kw...)
    if t !== nothing
        Base.depwarn("The `t` keyword argument to `sign_aws4!` is deprecated; use " *
                     "`timestamp` instead.", :sign_aws4!)
        timestamp = t
    end

    # ISO8601 date/time strings for time of request...
    date = Dates.format(timestamp, dateformat"yyyymmdd")
    datetime = Dates.format(timestamp, dateformat"yyyymmddTHHMMSS\Z")

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
    setkv(headers, "host", url.host)
    setkv(headers, "x-amz-date", datetime)
    include_md5 && setkv(headers, "Content-MD5", base64encode(body_md5))
    if (aws_service == "s3" && method == "PUT") || include_sha256
        # This header is required for S3 PUT requests. See the documentation at
        # https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
        setkv(headers, "x-amz-content-sha256", content_hash)
    end
    if aws_session_token != ""
        setkv(headers, "x-amz-security-token", aws_session_token)
    end

    # Sort and lowercase() Headers to produce canonical form...
    canonical_headers = sort!(map(headers) do (k, v)
        string(lowercase(k), ':', replace(strip(v), r"\s+" => " "))
    end)
    signed_headers = join(sort!(map(lowercase∘first, headers)), ";")

    # Sort Query String...
    query = sort!(collect(queryparams(url.query)), by=first)

    # Create hash of canonical request...
    canonical_form = join([method,
                           aws_service == "s3" ? url.path : escapepath(url.path),
                           escapeuri(query),
                           join(canonical_headers, "\n"),
                           "",
                           signed_headers,
                           content_hash], "\n")
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

end # module AWS4AuthRequest
