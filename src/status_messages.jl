"""
    statustext(::Int) -> String

`String` representation of a HTTP status code.

## Examples
```julia
julia> statustext(200)
"OK"

julia> statustext(404)
"Not Found"
```
"""
statustext(status) = Base.get(STATUS_MESSAGES, status, "Unknown Code")

const STATUS_MESSAGES = (()->begin
    v = fill("Unknown Code", 530)
    v[CONTINUE] = "Continue"
    v[SWITCHING_PROTOCOLS] = "Switching Protocols"
    v[PROCESSING] = "Processing"                                                # RFC 2518 => obsoleted by RFC 4918
    v[EARLY_HINTS] = "Early Hints"
    v[OK] = "OK"
    v[CREATED] = "Created"
    v[ACCEPTED] = "Accepted"
    v[NON_AUTHORITATIVE_INFORMATION] = "Non-Authoritative Information"
    v[NO_CONTENT] = "No Content"
    v[RESET_CONTENT] = "Reset Content"
    v[PARTIAL_CONTENT] = "Partial Content"
    v[MULTI_STATUS] = "Multi-Status"                                            # RFC4918
    v[ALREADY_REPORTED] = "Already Reported"                                    # RFC5842
    v[IM_USED] = "IM Used"                                                      # RFC3229
    v[MULTIPLE_CHOICES] = "Multiple Choices"
    v[MOVED_PERMANENTLY] = "Moved Permanently"
    v[MOVED_TEMPORARILY] = "Moved Temporarily"
    v[SEE_OTHER] = "See Other"
    v[NOT_MODIFIED] = "Not Modified"
    v[USE_PROXY] = "Use Proxy"
    v[TEMPORARY_REDIRECT] = "Temporary Redirect"
    v[PERMANENT_REDIRECT] = "Permanent Redirect"                                # RFC7238
    v[BAD_REQUEST] = "Bad Request"
    v[UNAUTHORIZED] = "Unauthorized"
    v[PAYMENT_REQUIRED] = "Payment Required"
    v[FORBIDDEN] = "Forbidden"
    v[NOT_FOUND] = "Not Found"
    v[METHOD_NOT_ALLOWED] = "Method Not Allowed"
    v[NOT_ACCEPTABLE] = "Not Acceptable"
    v[PROXY_AUTHENTICATION_REQUIRED] = "Proxy Authentication Required"
    v[REQUEST_TIME_OUT] = "Request Time-out"
    v[CONFLICT] = "Conflict"
    v[GONE] = "Gone"
    v[LENGTH_REQUIRED] = "Length Required"
    v[PRECONDITION_FAILED] = "Precondition Failed"
    v[REQUEST_ENTITY_TOO_LARGE] = "Request Entity Too Large"
    v[REQUEST_URI_TOO_LARGE] = "Request-URI Too Large"
    v[UNSUPPORTED_MEDIA_TYPE] = "Unsupported Media Type"
    v[REQUESTED_RANGE_NOT_SATISFIABLE] = "Requested Range Not Satisfiable"
    v[EXPECTATION_FAILED] = "Expectation Failed"
    v[IM_A_TEAPOT] = "I'm a teapot"                                             # RFC 2324
    v[MISDIRECTED_REQUEST] = "Misdirected Request"                              # RFC 7540
    v[UNPROCESSABLE_ENTITY] = "Unprocessable Entity"                            # RFC 4918
    v[LOCKED] = "Locked"                                                        # RFC 4918
    v[FAILED_DEPENDENCY] = "Failed Dependency"                                  # RFC 4918
    v[UNORDERED_COLLECTION] = "Unordered Collection"                            # RFC 4918
    v[UPGRADE_REQUIRED] = "Upgrade Required"                                    # RFC 2817
    v[PRECONDITION_REQUIRED] = "Precondition Required"                          # RFC 6585
    v[TOO_MANY_REQUESTS] = "Too Many Requests"                                  # RFC 6585
    v[REQUEST_HEADER_FIELDS_TOO_LARGE] = "Request Header Fields Too Large"      # RFC 6585
    v[LOGIN_TIMEOUT] = "Login Timeout"
    v[NGINX_ERROR_NO_RESPONSE] = "nginx error: No Response"
    v[UNAVAILABLE_FOR_LEGAL_REASONS] = "Unavailable For Legal Reasons"          # RFC7725
    v[NGINX_ERROR_SSL_CERTIFICATE_ERROR] = "nginx error: SSL Certificate Error"
    v[NGINX_ERROR_SSL_CERTIFICATE_REQUIRED] = "nginx error: SSL Certificate Required"
    v[NGINX_ERROR_HTTP_TO_HTTPS] = "nginx error: HTTP -> HTTPS"
    v[NGINX_ERROR_OR_ANTIVIRUS_INTERCEPTED_REQUEST_OR_ARCGIS_ERROR] = "nginx error or Antivirus intercepted request or ArcGIS error"
    v[INTERNAL_SERVER_ERROR] = "Internal Server Error"
    v[NOT_IMPLEMENTED] = "Not Implemented"
    v[BAD_GATEWAY] = "Bad Gateway"
    v[SERVICE_UNAVAILABLE] = "Service Unavailable"
    v[GATEWAY_TIME_OUT] = "Gateway Time-out"
    v[HTTP_VERSION_NOT_SUPPORTED] = "HTTP Version Not Supported"
    v[VARIANT_ALSO_NEGOTIATES] = "Variant Also Negotiates"                      # RFC 2295
    v[INSUFFICIENT_STORAGE] = "Insufficient Storage"                            # RFC 4918
    v[LOOP_DETECTED] = "Loop Detected"                                          # RFC5842
    v[BANDWIDTH_LIMIT_EXCEEDED] = "Bandwidth Limit Exceeded"
    v[NOT_EXTENDED] = "Not Extended"                                            # RFC 2774
    v[NETWORK_AUTHENTICATION_REQUIRED] = "Network Authentication Required"      # RFC 6585
    v[CLOUDFLARE_SERVER_ERROR_UNKNOWN] = "CloudFlare Server Error: Unknown"
    v[CLOUDFLARE_SERVER_ERROR_CONNECTION_REFUSED] = "CloudFlare Server Error: Connection Refused"
    v[CLOUDFLARE_SERVER_ERROR_CONNECTION_TIMEOUT] = "CloudFlare Server Error: Connection Timeout"
    v[CLOUDFLARE_SERVER_ERROR_ORIGIN_SERVER_UNREACHABLE] = "CloudFlare Server Error: Origin Server Unreachable"
    v[CLOUDFLARE_SERVER_ERROR_A_TIMEOUT] = "CloudFlare Server Error: A Timeout"
    v[CLOUDFLARE_SERVER_ERROR_CONNECTION_FAILED] = "CloudFlare Server Error: Connection Failed"
    v[CLOUDFLARE_SERVER_ERROR_INVALID_SSL_CERITIFICATE] = "CloudFlare Server Error: Invalid SSL Ceritificate"
    v[CLOUDFLARE_SERVER_ERROR_RAILGUN_ERROR] = "CloudFlare Server Error: Railgun Error"
    v[SITE_FROZEN] = "Site Frozen"
    return v
end)()
