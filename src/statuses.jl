"""
This module provides HTTP status code constatnts and related functions 
"""
module StatusCodes

export statustext

# Status code definitions
const CONTINUE =                                                     100
const SWITCHING_PROTOCOLS =                                          101
const PROCESSING =                                                   102
const EARLY_HINTS =                                                  103
const OK =                                                           200
const CREATED =                                                      201
const ACCEPTED =                                                     202
const NON_AUTHORITATIVE_INFORMATION =                                203
const NO_CONTENT =                                                   204
const RESET_CONTENT =                                                205
const PARTIAL_CONTENT =                                              206
const MULTI_STATUS =                                                 207
const ALREADY_REPORTED =                                             208
const IM_USED =                                                      226
const MULTIPLE_CHOICES =                                             300
const MOVED_PERMANENTLY =                                            301
const MOVED_TEMPORARILY =                                            302
const SEE_OTHER =                                                    303
const NOT_MODIFIED =                                                 304
const USE_PROXY =                                                    305
const TEMPORARY_REDIRECT =                                           307
const PERMANENT_REDIRECT =                                           308
const BAD_REQUEST =                                                  400
const UNAUTHORIZED =                                                 401
const PAYMENT_REQUIRED =                                             402
const FORBIDDEN =                                                    403
const NOT_FOUND =                                                    404
const METHOD_NOT_ALLOWED =                                           405
const NOT_ACCEPTABLE =                                               406
const PROXY_AUTHENTICATION_REQUIRED =                                407
const REQUEST_TIME_OUT =                                             408
const CONFLICT =                                                     409
const GONE =                                                         410
const LENGTH_REQUIRED =                                              411
const PRECONDITION_FAILED =                                          412
const REQUEST_ENTITY_TOO_LARGE =                                     413
const REQUEST_URI_TOO_LARGE =                                        414
const UNSUPPORTED_MEDIA_TYPE =                                       415
const REQUESTED_RANGE_NOT_SATISFIABLE =                              416
const EXPECTATION_FAILED =                                           417
const IM_A_TEAPOT =                                                  418
const MISDIRECTED_REQUEST =                                          421
const UNPROCESSABLE_ENTITY =                                         422
const LOCKED =                                                       423
const FAILED_DEPENDENCY =                                            424
const UNORDERED_COLLECTION =                                         425
const UPGRADE_REQUIRED =                                             426
const PRECONDITION_REQUIRED =                                        428
const TOO_MANY_REQUESTS =                                            429
const REQUEST_HEADER_FIELDS_TOO_LARGE =                              431
const LOGIN_TIMEOUT =                                                440
const NGINX_ERROR_NO_RESPONSE =                                      444
const UNAVAILABLE_FOR_LEGAL_REASONS =                                451
const NGINX_ERROR_SSL_CERTIFICATE_ERROR =                            495
const NGINX_ERROR_SSL_CERTIFICATE_REQUIRED =                         496
const NGINX_ERROR_HTTP_TO_HTTPS =                                    497
const NGINX_ERROR_OR_ANTIVIRUS_INTERCEPTED_REQUEST_OR_ARCGIS_ERROR = 499
const INTERNAL_SERVER_ERROR =                                        500
const NOT_IMPLEMENTED =                                              501
const BAD_GATEWAY =                                                  502
const SERVICE_UNAVAILABLE =                                          503
const GATEWAY_TIME_OUT =                                             504
const HTTP_VERSION_NOT_SUPPORTED =                                   505
const VARIANT_ALSO_NEGOTIATES =                                      506
const INSUFFICIENT_STORAGE =                                         507
const LOOP_DETECTED =                                                508
const BANDWIDTH_LIMIT_EXCEEDED =                                     509
const NOT_EXTENDED =                                                 510
const NETWORK_AUTHENTICATION_REQUIRED =                              511
const CLOUDFLARE_SERVER_ERROR_UNKNOWN =                              520
const CLOUDFLARE_SERVER_ERROR_CONNECTION_REFUSED =                   521
const CLOUDFLARE_SERVER_ERROR_CONNECTION_TIMEOUT =                   522
const CLOUDFLARE_SERVER_ERROR_ORIGIN_SERVER_UNREACHABLE =            523
const CLOUDFLARE_SERVER_ERROR_A_TIMEOUT =                            524
const CLOUDFLARE_SERVER_ERROR_CONNECTION_FAILED =                    525
const CLOUDFLARE_SERVER_ERROR_INVALID_SSL_CERITIFICATE =             526
const CLOUDFLARE_SERVER_ERROR_RAILGUN_ERROR =                        527
const SITE_FROZEN =                                                  530

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

end # module StatusCodes
