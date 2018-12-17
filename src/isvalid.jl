include("parseutils.jl")

"""
https://tools.ietf.org/html/rfc7230#section-3.1.1
request-line = method SP request-target SP HTTP-version CRLF
"""
const request_line_regex = r"""^
    (?: \r? \n) ?                       #    ignore leading blank line
    [!#$%&'*+\-.^_`|~[:alnum:]]+ [ ]+   # 1. method = token (RFC7230 3.2.6)
    [^.][^ \r\n]* [ ]+                  # 2. target
    HTTP/\d\.\d                         # 3. version
    \r? \n                              #    CRLF
"""x

"""
https://tools.ietf.org/html/rfc7230#section-3.1.2
status-line = HTTP-version SP status-code SP reason-phrase CRLF

See:
[#190](https://github.com/JuliaWeb/HTTP.jl/issues/190#issuecomment-363314009)
"""
const status_line_regex = r"""^
    [ ]?                                # Issue #190
    HTTP/\d\.\d [ ]+                    # 1. version
    \d\d\d .*                           # 2. status
    \r? \n                              #    CRLF
"""x

"""
https://tools.ietf.org/html/rfc7230#section-3.2
header-field = field-name ":" OWS field-value OWS
"""
const header_fields_regex = r"""
(?:
    [!#$%&'*+\-.^_`|~[:alnum:]]+ :      # 1. field-name = token (RFC7230 3.2.6)
    [ \t]*                              #    OWS
    [^\r\n]*?                           # 2. field-value
    [ \t]*                              #    OWS
    \r? \n                              #    CRLF
)*
"""x

"""
https://tools.ietf.org/html/rfc7230#section-3.2.4
obs-fold = CRLF 1*( SP / HTAB )
"""
const obs_fold_header_fields_regex = r"""
(?:
    [!#$%&'*+\-.^_`|~[:alnum:]]+ :      # 1. field-name = token (RFC7230 3.2.6)
    [ \t]*                              #    OWS
    (?: [^\r\n]*                        # 2. field-value
        (?: \r? \n [ \t] [^\r\n]*)*)    #    obs-fold
    [ \t]*                              #    OWS
    \r? \n                              #    CRLF
)*
"""x

const request_header_regex = Regex(request_line_regex.pattern *
                                   header_fields_regex.pattern *
                                   r"\r? \n$".pattern, "x")

const obs_request_header_regex = Regex(request_line_regex.pattern *
                                       obs_fold_header_fields_regex.pattern *
                                       r"\r? \n$".pattern, "x")

const response_header_regex = Regex(status_line_regex.pattern *
                                    header_fields_regex.pattern *
                                    r"\r? \n$".pattern, "x")

const obs_response_header_regex = Regex(status_line_regex.pattern *
                                        obs_fold_header_fields_regex.pattern *
                                        r"\r? \n$".pattern, "x")

function __init__()
    # FIXME Consider turing off `PCRE.UTF` in `Regex.compile_options`
    # https://github.com/JuliaLang/julia/pull/26731#issuecomment-380676770
    Base.compile(request_header_regex)
    Base.compile(obs_request_header_regex)
    Base.compile(response_header_regex)
    Base.compile(obs_response_header_regex)
end

Base.isvalid(h::RequestHeader; obs=false) =
    ismatch(obs ? obs_request_header_regex : request_header_regex, h.s)

Base.isvalid(h::ResponseHeader; obs=false) =
    ismatch(obs ? obs_response_header_regex : response_header_regex, h.s)

ismatch(r, s) = exec(r, s)
ismatch(r, s::IOBuffer) = exec(r, view(s.data, 1:s.size))
