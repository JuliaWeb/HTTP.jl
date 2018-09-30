"""
    statustext(::Int) -> String

`String` representation of a HTTP status code. e.g. `200 => "OK"`.
"""
statustext(status) = Base.get(STATUS_MESSAGES, status, "Unknown Code")

const STATUS_MESSAGES = (()->begin
    v = fill("Unknown Code", 530)
    v[100] = "Continue"
    v[101] = "Switching Protocols"
    v[102] = "Processing"                            # RFC 2518 => obsoleted by RFC 4918
    v[200] = "OK"
    v[201] = "Created"
    v[202] = "Accepted"
    v[203] = "Non-Authoritative Information"
    v[204] = "No Content"
    v[205] = "Reset Content"
    v[206] = "Partial Content"
    v[207] = "Multi-Status"                          # RFC 4918
    v[300] = "Multiple Choices"
    v[301] = "Moved Permanently"
    v[302] = "Moved Temporarily"
    v[303] = "See Other"
    v[304] = "Not Modified"
    v[305] = "Use Proxy"
    v[307] = "Temporary Redirect"
    v[400] = "Bad Request"
    v[401] = "Unauthorized"
    v[402] = "Payment Required"
    v[403] = "Forbidden"
    v[404] = "Not Found"
    v[405] = "Method Not Allowed"
    v[406] = "Not Acceptable"
    v[407] = "Proxy Authentication Required"
    v[408] = "Request Time-out"
    v[409] = "Conflict"
    v[410] = "Gone"
    v[411] = "Length Required"
    v[412] = "Precondition Failed"
    v[413] = "Request Entity Too Large"
    v[414] = "Request-URI Too Large"
    v[415] = "Unsupported Media Type"
    v[416] = "Requested Range Not Satisfiable"
    v[417] = "Expectation Failed"
    v[418] = "I'm a teapot"                        # RFC 2324
    v[422] = "Unprocessable Entity"                # RFC 4918
    v[423] = "Locked"                              # RFC 4918
    v[424] = "Failed Dependency"                   # RFC 4918
    v[425] = "Unordered Collection"                # RFC 4918
    v[426] = "Upgrade Required"                    # RFC 2817
    v[428] = "Precondition Required"               # RFC 6585
    v[429] = "Too Many Requests"                   # RFC 6585
    v[431] = "Request Header Fields Too Large"     # RFC 6585
    v[440] = "Login Timeout"
    v[444] = "nginx error: No Response"
    v[495] = "nginx error: SSL Certificate Error"
    v[496] = "nginx error: SSL Certificate Required"
    v[497] = "nginx error: HTTP -> HTTPS"
    v[499] = "nginx error or Antivirus intercepted request or ArcGIS error"
    v[500] = "Internal Server Error"
    v[501] = "Not Implemented"
    v[502] = "Bad Gateway"
    v[503] = "Service Unavailable"
    v[504] = "Gateway Time-out"
    v[505] = "HTTP Version Not Supported"
    v[506] = "Variant Also Negotiates"             # RFC 2295
    v[507] = "Insufficient Storage"                # RFC 4918
    v[509] = "Bandwidth Limit Exceeded"
    v[510] = "Not Extended"                        # RFC 2774
    v[511] = "Network Authentication Required"     # RFC 6585
    v[520] = "CloudFlare Server Error: Unknown"
    v[521] = "CloudFlare Server Error: Connection Refused"
    v[522] = "CloudFlare Server Error: Connection Timeout"
    v[523] = "CloudFlare Server Error: Origin Server Unreachable"
    v[524] = "CloudFlare Server Error: Connection Timeout"
    v[525] = "CloudFlare Server Error: Connection Failed"
    v[526] = "CloudFlare Server Error: Invalid SSL Ceritificate"
    v[527] = "CloudFlare Server Error: Railgun Error"
    v[530] = "Site Frozen"
    return v
end)()
