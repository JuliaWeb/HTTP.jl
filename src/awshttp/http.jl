# AWS HTTP Library - Core definitions
# Port of aws-c-http/include/aws/http/http.h, http_impl.h, status_code.h, http.c

using EnumX

const HTTP_PACKAGE_ID = 2

# ─── Error codes (aws_http_errors) ───

const ERROR_HTTP_UNKNOWN = ERROR_ENUM_BEGIN_RANGE(HTTP_PACKAGE_ID)
const ERROR_HTTP_HEADER_NOT_FOUND = ERROR_HTTP_UNKNOWN + 1
const ERROR_HTTP_INVALID_HEADER_FIELD = ERROR_HTTP_HEADER_NOT_FOUND + 1
const ERROR_HTTP_INVALID_HEADER_NAME = ERROR_HTTP_INVALID_HEADER_FIELD + 1
const ERROR_HTTP_INVALID_HEADER_VALUE = ERROR_HTTP_INVALID_HEADER_NAME + 1
const ERROR_HTTP_INVALID_METHOD = ERROR_HTTP_INVALID_HEADER_VALUE + 1
const ERROR_HTTP_INVALID_PATH = ERROR_HTTP_INVALID_METHOD + 1
const ERROR_HTTP_INVALID_STATUS_CODE = ERROR_HTTP_INVALID_PATH + 1
const ERROR_HTTP_MISSING_BODY_STREAM = ERROR_HTTP_INVALID_STATUS_CODE + 1
const ERROR_HTTP_INVALID_BODY_STREAM = ERROR_HTTP_MISSING_BODY_STREAM + 1
const ERROR_HTTP_CONNECTION_CLOSED = ERROR_HTTP_INVALID_BODY_STREAM + 1
const ERROR_HTTP_SWITCHED_PROTOCOLS = ERROR_HTTP_CONNECTION_CLOSED + 1
const ERROR_HTTP_UNSUPPORTED_PROTOCOL = ERROR_HTTP_SWITCHED_PROTOCOLS + 1
const ERROR_HTTP_REACTION_REQUIRED = ERROR_HTTP_UNSUPPORTED_PROTOCOL + 1
const ERROR_HTTP_DATA_NOT_AVAILABLE = ERROR_HTTP_REACTION_REQUIRED + 1
const ERROR_HTTP_OUTGOING_STREAM_LENGTH_INCORRECT = ERROR_HTTP_DATA_NOT_AVAILABLE + 1
const ERROR_HTTP_CALLBACK_FAILURE = ERROR_HTTP_OUTGOING_STREAM_LENGTH_INCORRECT + 1
const ERROR_HTTP_WEBSOCKET_UPGRADE_FAILURE = ERROR_HTTP_CALLBACK_FAILURE + 1
const ERROR_HTTP_WEBSOCKET_CLOSE_FRAME_SENT = ERROR_HTTP_WEBSOCKET_UPGRADE_FAILURE + 1
const ERROR_HTTP_WEBSOCKET_IS_MIDCHANNEL_HANDLER = ERROR_HTTP_WEBSOCKET_CLOSE_FRAME_SENT + 1
const ERROR_HTTP_CONNECTION_MANAGER_INVALID_STATE_FOR_ACQUIRE = ERROR_HTTP_WEBSOCKET_IS_MIDCHANNEL_HANDLER + 1
const ERROR_HTTP_CONNECTION_MANAGER_VENDED_CONNECTION_UNDERFLOW = ERROR_HTTP_CONNECTION_MANAGER_INVALID_STATE_FOR_ACQUIRE + 1
const ERROR_HTTP_SERVER_CLOSED = ERROR_HTTP_CONNECTION_MANAGER_VENDED_CONNECTION_UNDERFLOW + 1
const ERROR_HTTP_PROXY_CONNECT_FAILED = ERROR_HTTP_SERVER_CLOSED + 1
const ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN = ERROR_HTTP_PROXY_CONNECT_FAILED + 1
const ERROR_HTTP_CHANNEL_THROUGHPUT_FAILURE = ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN + 1
const ERROR_HTTP_PROTOCOL_ERROR = ERROR_HTTP_CHANNEL_THROUGHPUT_FAILURE + 1
const ERROR_HTTP_STREAM_IDS_EXHAUSTED = ERROR_HTTP_PROTOCOL_ERROR + 1
const ERROR_HTTP_GOAWAY_RECEIVED = ERROR_HTTP_STREAM_IDS_EXHAUSTED + 1
const ERROR_HTTP_RST_STREAM_RECEIVED = ERROR_HTTP_GOAWAY_RECEIVED + 1
const ERROR_HTTP_RST_STREAM_SENT = ERROR_HTTP_RST_STREAM_RECEIVED + 1
const ERROR_HTTP_STREAM_NOT_ACTIVATED = ERROR_HTTP_RST_STREAM_SENT + 1
const ERROR_HTTP_STREAM_HAS_COMPLETED = ERROR_HTTP_STREAM_NOT_ACTIVATED + 1
const ERROR_HTTP_PROXY_STRATEGY_NTLM_CHALLENGE_TOKEN_MISSING = ERROR_HTTP_STREAM_HAS_COMPLETED + 1
const ERROR_HTTP_PROXY_STRATEGY_TOKEN_RETRIEVAL_FAILURE = ERROR_HTTP_PROXY_STRATEGY_NTLM_CHALLENGE_TOKEN_MISSING + 1
const ERROR_HTTP_PROXY_CONNECT_FAILED_RETRYABLE = ERROR_HTTP_PROXY_STRATEGY_TOKEN_RETRIEVAL_FAILURE + 1
const ERROR_HTTP_PROTOCOL_SWITCH_FAILURE = ERROR_HTTP_PROXY_CONNECT_FAILED_RETRYABLE + 1
const ERROR_HTTP_MAX_CONCURRENT_STREAMS_EXCEEDED = ERROR_HTTP_PROTOCOL_SWITCH_FAILURE + 1
const ERROR_HTTP_STREAM_MANAGER_SHUTTING_DOWN = ERROR_HTTP_MAX_CONCURRENT_STREAMS_EXCEEDED + 1
const ERROR_HTTP_STREAM_MANAGER_CONNECTION_ACQUIRE_FAILURE = ERROR_HTTP_STREAM_MANAGER_SHUTTING_DOWN + 1
const ERROR_HTTP_STREAM_MANAGER_UNEXPECTED_HTTP_VERSION = ERROR_HTTP_STREAM_MANAGER_CONNECTION_ACQUIRE_FAILURE + 1
const ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR = ERROR_HTTP_STREAM_MANAGER_UNEXPECTED_HTTP_VERSION + 1
const ERROR_HTTP_MANUAL_WRITE_NOT_ENABLED = ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR + 1
const ERROR_HTTP_MANUAL_WRITE_HAS_COMPLETED = ERROR_HTTP_MANUAL_WRITE_NOT_ENABLED + 1
const ERROR_HTTP_RESPONSE_FIRST_BYTE_TIMEOUT = ERROR_HTTP_MANUAL_WRITE_HAS_COMPLETED + 1
const ERROR_HTTP_CONNECTION_MANAGER_ACQUISITION_TIMEOUT = ERROR_HTTP_RESPONSE_FIRST_BYTE_TIMEOUT + 1
const ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED = ERROR_HTTP_CONNECTION_MANAGER_ACQUISITION_TIMEOUT + 1
const ERROR_HTTP_STREAM_CANCELLED = ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED + 1
const ERROR_HTTP_STREAM_WINDOW_EXCEEDED = ERROR_HTTP_STREAM_CANCELLED + 1
const ERROR_HTTP_END_RANGE = ERROR_ENUM_END_RANGE(HTTP_PACKAGE_ID)

# Error description strings (indexed by code - begin_range)
const _HTTP_ERROR_STRINGS = Dict{Int, Tuple{String, String}}(
    ERROR_HTTP_UNKNOWN => ("ERROR_HTTP_UNKNOWN", "Encountered an unknown error."),
    ERROR_HTTP_HEADER_NOT_FOUND => ("ERROR_HTTP_HEADER_NOT_FOUND", "The specified header was not found"),
    ERROR_HTTP_INVALID_HEADER_FIELD => ("ERROR_HTTP_INVALID_HEADER_FIELD", "Invalid header field, including a forbidden header field."),
    ERROR_HTTP_INVALID_HEADER_NAME => ("ERROR_HTTP_INVALID_HEADER_NAME", "Invalid header name."),
    ERROR_HTTP_INVALID_HEADER_VALUE => ("ERROR_HTTP_INVALID_HEADER_VALUE", "Invalid header value."),
    ERROR_HTTP_INVALID_METHOD => ("ERROR_HTTP_INVALID_METHOD", "Method is invalid."),
    ERROR_HTTP_INVALID_PATH => ("ERROR_HTTP_INVALID_PATH", "Path is invalid."),
    ERROR_HTTP_INVALID_STATUS_CODE => ("ERROR_HTTP_INVALID_STATUS_CODE", "Status code is invalid."),
    ERROR_HTTP_MISSING_BODY_STREAM => ("ERROR_HTTP_MISSING_BODY_STREAM", "Given the provided headers (ex: Content-Length), a body is expected."),
    ERROR_HTTP_INVALID_BODY_STREAM => ("ERROR_HTTP_INVALID_BODY_STREAM", "A body stream provided, but the message does not allow body."),
    ERROR_HTTP_CONNECTION_CLOSED => ("ERROR_HTTP_CONNECTION_CLOSED", "The connection has closed or is closing."),
    ERROR_HTTP_SWITCHED_PROTOCOLS => ("ERROR_HTTP_SWITCHED_PROTOCOLS", "The connection has switched protocols."),
    ERROR_HTTP_UNSUPPORTED_PROTOCOL => ("ERROR_HTTP_UNSUPPORTED_PROTOCOL", "An unsupported protocol was encountered."),
    ERROR_HTTP_REACTION_REQUIRED => ("ERROR_HTTP_REACTION_REQUIRED", "A necessary function was not invoked from a user callback."),
    ERROR_HTTP_DATA_NOT_AVAILABLE => ("ERROR_HTTP_DATA_NOT_AVAILABLE", "This data is not yet available."),
    ERROR_HTTP_OUTGOING_STREAM_LENGTH_INCORRECT => ("ERROR_HTTP_OUTGOING_STREAM_LENGTH_INCORRECT", "Amount of data streamed out does not match the previously declared length."),
    ERROR_HTTP_CALLBACK_FAILURE => ("ERROR_HTTP_CALLBACK_FAILURE", "A callback has reported failure."),
    ERROR_HTTP_WEBSOCKET_UPGRADE_FAILURE => ("ERROR_HTTP_WEBSOCKET_UPGRADE_FAILURE", "Failed to upgrade HTTP connection to Websocket."),
    ERROR_HTTP_WEBSOCKET_CLOSE_FRAME_SENT => ("ERROR_HTTP_WEBSOCKET_CLOSE_FRAME_SENT", "Websocket has sent CLOSE frame, no more data will be sent."),
    ERROR_HTTP_WEBSOCKET_IS_MIDCHANNEL_HANDLER => ("ERROR_HTTP_WEBSOCKET_IS_MIDCHANNEL_HANDLER", "Operation cannot be performed because websocket has been converted to a midchannel handler."),
    ERROR_HTTP_CONNECTION_MANAGER_INVALID_STATE_FOR_ACQUIRE => ("ERROR_HTTP_CONNECTION_MANAGER_INVALID_STATE_FOR_ACQUIRE", "Acquire called after the connection manager's ref count has reached zero"),
    ERROR_HTTP_CONNECTION_MANAGER_VENDED_CONNECTION_UNDERFLOW => ("ERROR_HTTP_CONNECTION_MANAGER_VENDED_CONNECTION_UNDERFLOW", "Release called when the connection manager's vended connection count was zero"),
    ERROR_HTTP_SERVER_CLOSED => ("ERROR_HTTP_SERVER_CLOSED", "The http server is closed, no more connections will be accepted"),
    ERROR_HTTP_PROXY_CONNECT_FAILED => ("ERROR_HTTP_PROXY_CONNECT_FAILED", "Proxy-based connection establishment failed because the CONNECT call failed"),
    ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN => ("ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN", "Connection acquisition failed because connection manager is shutting down"),
    ERROR_HTTP_CHANNEL_THROUGHPUT_FAILURE => ("ERROR_HTTP_CHANNEL_THROUGHPUT_FAILURE", "Http connection channel shut down due to failure to meet throughput minimum"),
    ERROR_HTTP_PROTOCOL_ERROR => ("ERROR_HTTP_PROTOCOL_ERROR", "Protocol rules violated by peer"),
    ERROR_HTTP_STREAM_IDS_EXHAUSTED => ("ERROR_HTTP_STREAM_IDS_EXHAUSTED", "Connection exhausted all possible HTTP-stream IDs."),
    ERROR_HTTP_GOAWAY_RECEIVED => ("ERROR_HTTP_GOAWAY_RECEIVED", "Peer sent GOAWAY to initiate connection shutdown."),
    ERROR_HTTP_RST_STREAM_RECEIVED => ("ERROR_HTTP_RST_STREAM_RECEIVED", "Peer sent RST_STREAM to terminate HTTP-stream."),
    ERROR_HTTP_RST_STREAM_SENT => ("ERROR_HTTP_RST_STREAM_SENT", "RST_STREAM has sent from local implementation and HTTP-stream has been terminated."),
    ERROR_HTTP_STREAM_NOT_ACTIVATED => ("ERROR_HTTP_STREAM_NOT_ACTIVATED", "HTTP-stream must be activated before use."),
    ERROR_HTTP_STREAM_HAS_COMPLETED => ("ERROR_HTTP_STREAM_HAS_COMPLETED", "HTTP-stream has completed, action cannot be performed."),
    ERROR_HTTP_PROXY_STRATEGY_NTLM_CHALLENGE_TOKEN_MISSING => ("ERROR_HTTP_PROXY_STRATEGY_NTLM_CHALLENGE_TOKEN_MISSING", "NTLM Proxy strategy was initiated without a challenge token"),
    ERROR_HTTP_PROXY_STRATEGY_TOKEN_RETRIEVAL_FAILURE => ("ERROR_HTTP_PROXY_STRATEGY_TOKEN_RETRIEVAL_FAILURE", "Failure in user code while retrieving proxy auth token"),
    ERROR_HTTP_PROXY_CONNECT_FAILED_RETRYABLE => ("ERROR_HTTP_PROXY_CONNECT_FAILED_RETRYABLE", "Proxy connection attempt failed but the negotiation could be continued on a new connection"),
    ERROR_HTTP_PROTOCOL_SWITCH_FAILURE => ("ERROR_HTTP_PROTOCOL_SWITCH_FAILURE", "Internal state failure prevent connection from switching protocols"),
    ERROR_HTTP_MAX_CONCURRENT_STREAMS_EXCEEDED => ("ERROR_HTTP_MAX_CONCURRENT_STREAMS_EXCEEDED", "Max concurrent stream reached"),
    ERROR_HTTP_STREAM_MANAGER_SHUTTING_DOWN => ("ERROR_HTTP_STREAM_MANAGER_SHUTTING_DOWN", "Stream acquisition failed because stream manager is shutting down"),
    ERROR_HTTP_STREAM_MANAGER_CONNECTION_ACQUIRE_FAILURE => ("ERROR_HTTP_STREAM_MANAGER_CONNECTION_ACQUIRE_FAILURE", "Stream acquisition failed because stream manager failed to acquire a connection"),
    ERROR_HTTP_STREAM_MANAGER_UNEXPECTED_HTTP_VERSION => ("ERROR_HTTP_STREAM_MANAGER_UNEXPECTED_HTTP_VERSION", "Stream acquisition failed because stream manager got an unexpected version of HTTP connection"),
    ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR => ("ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR", "Websocket protocol rules violated by peer"),
    ERROR_HTTP_MANUAL_WRITE_NOT_ENABLED => ("ERROR_HTTP_MANUAL_WRITE_NOT_ENABLED", "Manual write failed because manual writes are not enabled."),
    ERROR_HTTP_MANUAL_WRITE_HAS_COMPLETED => ("ERROR_HTTP_MANUAL_WRITE_HAS_COMPLETED", "Manual write failed because manual writes are already completed."),
    ERROR_HTTP_RESPONSE_FIRST_BYTE_TIMEOUT => ("ERROR_HTTP_RESPONSE_FIRST_BYTE_TIMEOUT", "Timed out waiting for first byte of HTTP response, after sending the full request."),
    ERROR_HTTP_CONNECTION_MANAGER_ACQUISITION_TIMEOUT => ("ERROR_HTTP_CONNECTION_MANAGER_ACQUISITION_TIMEOUT", "Connection Manager failed to acquire a connection within the defined timeout."),
    ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED => ("ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED", "Max pending acquisitions reached"),
    ERROR_HTTP_STREAM_CANCELLED => ("ERROR_HTTP_STREAM_CANCELLED", "HTTP-stream was cancelled."),
    ERROR_HTTP_STREAM_WINDOW_EXCEEDED => ("ERROR_HTTP_STREAM_WINDOW_EXCEEDED", "Incoming data exceeded the stream's flow-control window."),
)

"""
    http_error_str(code::Integer) -> String

Return a description string for an HTTP error code.
"""
function http_error_str(code::Integer)::String
    info = get(_HTTP_ERROR_STRINGS, code, nothing)
    return info === nothing ? "Unknown HTTP error" : info[2]
end

"""
    http_error_name(code::Integer) -> String

Return the symbolic name for an HTTP error code.
"""
function http_error_name(code::Integer)::String
    info = get(_HTTP_ERROR_STRINGS, code, nothing)
    return info === nothing ? "UNKNOWN" : info[1]
end

# ─── HTTP/2 error codes (aws_http2_error_code, RFC 7540 §7) ───

@enumx Http2ErrorCode::UInt32 begin
    NO_ERROR = 0x00
    PROTOCOL_ERROR = 0x01
    INTERNAL_ERROR = 0x02
    FLOW_CONTROL_ERROR = 0x03
    SETTINGS_TIMEOUT = 0x04
    STREAM_CLOSED = 0x05
    FRAME_SIZE_ERROR = 0x06
    REFUSED_STREAM = 0x07
    CANCEL = 0x08
    COMPRESSION_ERROR = 0x09
    CONNECT_ERROR = 0x0A
    ENHANCE_YOUR_CALM = 0x0B
    INADEQUATE_SECURITY = 0x0C
    HTTP_1_1_REQUIRED = 0x0D
end

const _H2_ERROR_STRINGS = Dict{Http2ErrorCode.T, String}(
    Http2ErrorCode.NO_ERROR => "NO_ERROR",
    Http2ErrorCode.PROTOCOL_ERROR => "PROTOCOL_ERROR",
    Http2ErrorCode.INTERNAL_ERROR => "INTERNAL_ERROR",
    Http2ErrorCode.FLOW_CONTROL_ERROR => "FLOW_CONTROL_ERROR",
    Http2ErrorCode.SETTINGS_TIMEOUT => "SETTINGS_TIMEOUT",
    Http2ErrorCode.STREAM_CLOSED => "STREAM_CLOSED",
    Http2ErrorCode.FRAME_SIZE_ERROR => "FRAME_SIZE_ERROR",
    Http2ErrorCode.REFUSED_STREAM => "REFUSED_STREAM",
    Http2ErrorCode.CANCEL => "CANCEL",
    Http2ErrorCode.COMPRESSION_ERROR => "COMPRESSION_ERROR",
    Http2ErrorCode.CONNECT_ERROR => "CONNECT_ERROR",
    Http2ErrorCode.ENHANCE_YOUR_CALM => "ENHANCE_YOUR_CALM",
    Http2ErrorCode.INADEQUATE_SECURITY => "INADEQUATE_SECURITY",
    Http2ErrorCode.HTTP_1_1_REQUIRED => "HTTP_1_1_REQUIRED",
)

"""
    http2_error_code_to_str(code::Http2ErrorCode.T) -> String

Return the string name of an HTTP/2 error code.
"""
function http2_error_code_to_str(code::Http2ErrorCode.T)::String
    return get(_H2_ERROR_STRINGS, code, "UNKNOWN_H2_ERROR")
end

# ─── Log subjects ───

const LS_HTTP_GENERAL = LOG_SUBJECT_BEGIN_RANGE(HTTP_PACKAGE_ID)
const LS_HTTP_CONNECTION = LS_HTTP_GENERAL + LogSubject(1)
const LS_HTTP_ENCODER = LS_HTTP_CONNECTION + LogSubject(1)
const LS_HTTP_DECODER = LS_HTTP_ENCODER + LogSubject(1)
const LS_HTTP_SERVER = LS_HTTP_DECODER + LogSubject(1)
const LS_HTTP_STREAM = LS_HTTP_SERVER + LogSubject(1)
const LS_HTTP_CONNECTION_MANAGER = LS_HTTP_STREAM + LogSubject(1)
const LS_HTTP_STREAM_MANAGER = LS_HTTP_CONNECTION_MANAGER + LogSubject(1)
const LS_HTTP_WEBSOCKET = LS_HTTP_STREAM_MANAGER + LogSubject(1)
const LS_HTTP_WEBSOCKET_SETUP = LS_HTTP_WEBSOCKET + LogSubject(1)
const LS_HTTP_PROXY_NEGOTIATION = LS_HTTP_WEBSOCKET_SETUP + LogSubject(1)
const LS_HTTP_LAST = LOG_SUBJECT_END_RANGE(HTTP_PACKAGE_ID)

# ─── HTTP version enum ───

@enumx HttpVersion::UInt8 begin
    UNKNOWN = 0
    HTTP_1_0 = 1
    HTTP_1_1 = 2
    HTTP_2 = 3
end

const _VERSION_STRINGS = Dict{HttpVersion.T, String}(
    HttpVersion.UNKNOWN => "Unknown",
    HttpVersion.HTTP_1_0 => "HTTP/1.0",
    HttpVersion.HTTP_1_1 => "HTTP/1.1",
    HttpVersion.HTTP_2 => "HTTP/2",
)

"""
    http_version_to_str(version::HttpVersion.T) -> String

Return string representation of an HTTP version.
"""
function http_version_to_str(version::HttpVersion.T)::String
    return get(_VERSION_STRINGS, version, "Unknown")
end

# ─── ALPN protocol map ───

"""
    HttpAlpnMap

Maps ALPN protocol strings (negotiated during TLS) to `HttpVersion` values.
Default mapping: "h2" → HTTP_2, "http/1.1" → HTTP_1_1.
"""
const HttpAlpnMap = Dict{String, HttpVersion.T}

"""
    http_alpn_map_init() -> HttpAlpnMap

Create a new ALPN map with default protocol mappings.
"""
function http_alpn_map_init()::HttpAlpnMap
    return HttpAlpnMap(
        "h2" => HttpVersion.HTTP_2,
        "http/1.1" => HttpVersion.HTTP_1_1,
    )
end

"""
    http_alpn_map_init_copy(source::HttpAlpnMap) -> HttpAlpnMap

Create a copy of an ALPN map.
"""
function http_alpn_map_init_copy(source::HttpAlpnMap)::HttpAlpnMap
    return copy(source)
end

"""
    http_alpn_map_add!(map::HttpAlpnMap, protocol::String, version::HttpVersion.T) -> Nothing

Add or update a mapping in the ALPN map.
"""
function http_alpn_map_add!(map::HttpAlpnMap, protocol::String, version::HttpVersion.T)::Nothing
    map[protocol] = version
    return nothing
end

"""
    http_alpn_map_get(map::HttpAlpnMap, protocol::String) -> HttpVersion.T

Look up an ALPN protocol string. Returns `HttpVersion.UNKNOWN` if not found.
"""
function http_alpn_map_get(map::HttpAlpnMap, protocol::String)::HttpVersion.T
    return get(map, protocol, HttpVersion.UNKNOWN)
end

# ─── HTTP status codes (status_code.h) ───

const HTTP_STATUS_CODE_UNKNOWN = -1

# 1xx Informational
const HTTP_STATUS_CODE_100_CONTINUE = 100
const HTTP_STATUS_CODE_101_SWITCHING_PROTOCOLS = 101
const HTTP_STATUS_CODE_102_PROCESSING = 102
const HTTP_STATUS_CODE_103_EARLY_HINTS = 103

# 2xx Success
const HTTP_STATUS_CODE_200_OK = 200
const HTTP_STATUS_CODE_201_CREATED = 201
const HTTP_STATUS_CODE_202_ACCEPTED = 202
const HTTP_STATUS_CODE_203_NON_AUTHORITATIVE_INFORMATION = 203
const HTTP_STATUS_CODE_204_NO_CONTENT = 204
const HTTP_STATUS_CODE_205_RESET_CONTENT = 205
const HTTP_STATUS_CODE_206_PARTIAL_CONTENT = 206
const HTTP_STATUS_CODE_207_MULTI_STATUS = 207
const HTTP_STATUS_CODE_208_ALREADY_REPORTED = 208
const HTTP_STATUS_CODE_226_IM_USED = 226

# 3xx Redirection
const HTTP_STATUS_CODE_300_MULTIPLE_CHOICES = 300
const HTTP_STATUS_CODE_301_MOVED_PERMANENTLY = 301
const HTTP_STATUS_CODE_302_FOUND = 302
const HTTP_STATUS_CODE_303_SEE_OTHER = 303
const HTTP_STATUS_CODE_304_NOT_MODIFIED = 304
const HTTP_STATUS_CODE_305_USE_PROXY = 305
const HTTP_STATUS_CODE_307_TEMPORARY_REDIRECT = 307
const HTTP_STATUS_CODE_308_PERMANENT_REDIRECT = 308

# 4xx Client Error
const HTTP_STATUS_CODE_400_BAD_REQUEST = 400
const HTTP_STATUS_CODE_401_UNAUTHORIZED = 401
const HTTP_STATUS_CODE_402_PAYMENT_REQUIRED = 402
const HTTP_STATUS_CODE_403_FORBIDDEN = 403
const HTTP_STATUS_CODE_404_NOT_FOUND = 404
const HTTP_STATUS_CODE_405_METHOD_NOT_ALLOWED = 405
const HTTP_STATUS_CODE_406_NOT_ACCEPTABLE = 406
const HTTP_STATUS_CODE_407_PROXY_AUTHENTICATION_REQUIRED = 407
const HTTP_STATUS_CODE_408_REQUEST_TIMEOUT = 408
const HTTP_STATUS_CODE_409_CONFLICT = 409
const HTTP_STATUS_CODE_410_GONE = 410
const HTTP_STATUS_CODE_411_LENGTH_REQUIRED = 411
const HTTP_STATUS_CODE_412_PRECONDITION_FAILED = 412
const HTTP_STATUS_CODE_413_REQUEST_ENTITY_TOO_LARGE = 413
const HTTP_STATUS_CODE_414_REQUEST_URI_TOO_LONG = 414
const HTTP_STATUS_CODE_415_UNSUPPORTED_MEDIA_TYPE = 415
const HTTP_STATUS_CODE_416_REQUESTED_RANGE_NOT_SATISFIABLE = 416
const HTTP_STATUS_CODE_417_EXPECTATION_FAILED = 417
const HTTP_STATUS_CODE_421_MISDIRECTED_REQUEST = 421
const HTTP_STATUS_CODE_422_UNPROCESSABLE_ENTITY = 422
const HTTP_STATUS_CODE_423_LOCKED = 423
const HTTP_STATUS_CODE_424_FAILED_DEPENDENCY = 424
const HTTP_STATUS_CODE_425_TOO_EARLY = 425
const HTTP_STATUS_CODE_426_UPGRADE_REQUIRED = 426
const HTTP_STATUS_CODE_428_PRECONDITION_REQUIRED = 428
const HTTP_STATUS_CODE_429_TOO_MANY_REQUESTS = 429
const HTTP_STATUS_CODE_431_REQUEST_HEADER_FIELDS_TOO_LARGE = 431
const HTTP_STATUS_CODE_451_UNAVAILABLE_FOR_LEGAL_REASON = 451

# 5xx Server Error
const HTTP_STATUS_CODE_500_INTERNAL_SERVER_ERROR = 500
const HTTP_STATUS_CODE_501_NOT_IMPLEMENTED = 501
const HTTP_STATUS_CODE_502_BAD_GATEWAY = 502
const HTTP_STATUS_CODE_503_SERVICE_UNAVAILABLE = 503
const HTTP_STATUS_CODE_504_GATEWAY_TIMEOUT = 504
const HTTP_STATUS_CODE_505_HTTP_VERSION_NOT_SUPPORTED = 505
const HTTP_STATUS_CODE_506_VARIANT_ALSO_NEGOTIATES = 506
const HTTP_STATUS_CODE_507_INSUFFICIENT_STORAGE = 507
const HTTP_STATUS_CODE_508_LOOP_DETECTED = 508
const HTTP_STATUS_CODE_510_NOT_EXTENDED = 510
const HTTP_STATUS_CODE_511_NETWORK_AUTHENTICATION_REQUIRED = 511

const _STATUS_TEXT = Dict{Int, String}(
    100 => "Continue",
    101 => "Switching Protocols",
    102 => "Processing",
    103 => "Early Hints",
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    203 => "Non-Authoritative Information",
    204 => "No Content",
    205 => "Reset Content",
    206 => "Partial Content",
    207 => "Multi-Status",
    208 => "Already Reported",
    226 => "IM Used",
    300 => "Multiple Choices",
    301 => "Moved Permanently",
    302 => "Found",
    303 => "See Other",
    304 => "Not Modified",
    305 => "Use Proxy",
    307 => "Temporary Redirect",
    308 => "Permanent Redirect",
    400 => "Bad Request",
    401 => "Unauthorized",
    402 => "Payment Required",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    406 => "Not Acceptable",
    407 => "Proxy Authentication Required",
    408 => "Request Timeout",
    409 => "Conflict",
    410 => "Gone",
    411 => "Length Required",
    412 => "Precondition Failed",
    413 => "Payload Too Large",
    414 => "URI Too Long",
    415 => "Unsupported Media Type",
    416 => "Range Not Satisfiable",
    417 => "Expectation Failed",
    421 => "Misdirected Request",
    422 => "Unprocessable Entity",
    423 => "Locked",
    424 => "Failed Dependency",
    425 => "Too Early",
    426 => "Upgrade Required",
    428 => "Precondition Required",
    429 => "Too Many Requests",
    431 => "Request Header Fields Too Large",
    451 => "Unavailable For Legal Reasons",
    500 => "Internal Server Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Timeout",
    505 => "HTTP Version Not Supported",
    506 => "Variant Also Negotiates",
    507 => "Insufficient Storage",
    508 => "Loop Detected",
    510 => "Not Extended",
    511 => "Network Authentication Required",
)

"""
    http_status_text(status_code::Integer) -> String

Return the description text for an HTTP status code.
Returns empty string for unrecognized codes.
"""
function http_status_text(status_code::Integer)::String
    return get(_STATUS_TEXT, Int(status_code), "")
end

# ─── HTTP method constants and enum ───

const HTTP_METHOD_GET = "GET"
const HTTP_METHOD_HEAD = "HEAD"
const HTTP_METHOD_POST = "POST"
const HTTP_METHOD_PUT = "PUT"
const HTTP_METHOD_DELETE = "DELETE"
const HTTP_METHOD_CONNECT = "CONNECT"
const HTTP_METHOD_OPTIONS = "OPTIONS"
const HTTP_METHOD_TRACE = "TRACE"
const HTTP_METHOD_PATCH = "PATCH"

@enumx HttpMethod::UInt8 begin
    UNKNOWN = 0
    GET = 1
    HEAD = 2
    POST = 3
    PUT = 4
    DELETE = 5
    CONNECT = 6
    OPTIONS = 7
    TRACE = 8
    PATCH = 9
end

# Case-sensitive method string lookup.
const _METHOD_STR_TO_ENUM = Dict{String, HttpMethod.T}(
    HTTP_METHOD_GET => HttpMethod.GET,
    HTTP_METHOD_HEAD => HttpMethod.HEAD,
    HTTP_METHOD_POST => HttpMethod.POST,
    HTTP_METHOD_PUT => HttpMethod.PUT,
    HTTP_METHOD_DELETE => HttpMethod.DELETE,
    HTTP_METHOD_CONNECT => HttpMethod.CONNECT,
    HTTP_METHOD_OPTIONS => HttpMethod.OPTIONS,
    HTTP_METHOD_TRACE => HttpMethod.TRACE,
    HTTP_METHOD_PATCH => HttpMethod.PATCH,
)

"""
    http_str_to_method(s::AbstractString) -> HttpMethod.T

Case-sensitive method string to enum lookup.
Returns `HttpMethod.UNKNOWN` for unrecognized methods.
"""
function http_str_to_method(s::AbstractString)::HttpMethod.T
    return get(_METHOD_STR_TO_ENUM, String(s), HttpMethod.UNKNOWN)
end

# ─── HTTP header name constants and enum ───

# Pseudo-header name strings
const HTTP_HEADER_METHOD_STR = ":method"
const HTTP_HEADER_SCHEME_STR = ":scheme"
const HTTP_HEADER_AUTHORITY_STR = ":authority"
const HTTP_HEADER_PATH_STR = ":path"
const HTTP_HEADER_STATUS_STR = ":status"

# Scheme strings
const HTTP_SCHEME_HTTP = "http"
const HTTP_SCHEME_HTTPS = "https"

@enumx HttpHeaderName::UInt8 begin
    UNKNOWN = 0
    # Request pseudo-headers
    METHOD = 1
    SCHEME = 2
    AUTHORITY = 3
    PATH = 4
    # Response pseudo-headers
    STATUS = 5
    # Regular headers
    CONNECTION = 6
    CONTENT_LENGTH = 7
    EXPECT = 8
    TRANSFER_ENCODING = 9
    COOKIE = 10
    SET_COOKIE = 11
    HOST = 12
    CACHE_CONTROL = 13
    MAX_FORWARDS = 14
    PRAGMA = 15
    RANGE = 16
    TE = 17
    CONTENT_ENCODING = 18
    CONTENT_TYPE = 19
    CONTENT_RANGE = 20
    TRAILER = 21
    WWW_AUTHENTICATE = 22
    AUTHORIZATION = 23
    PROXY_AUTHENTICATE = 24
    PROXY_AUTHORIZATION = 25
    AGE = 26
    EXPIRES = 27
    DATE = 28
    LOCATION = 29
    RETRY_AFTER = 30
    VARY = 31
    WARNING = 32
    UPGRADE = 33
    KEEP_ALIVE = 34
    PROXY_CONNECTION = 35
end

# Lowercase header name strings for enum mapping (all stored lowercase)
const _HEADER_ENUM_TO_STR = Dict{HttpHeaderName.T, String}(
    HttpHeaderName.METHOD => ":method",
    HttpHeaderName.SCHEME => ":scheme",
    HttpHeaderName.AUTHORITY => ":authority",
    HttpHeaderName.PATH => ":path",
    HttpHeaderName.STATUS => ":status",
    HttpHeaderName.CONNECTION => "connection",
    HttpHeaderName.CONTENT_LENGTH => "content-length",
    HttpHeaderName.EXPECT => "expect",
    HttpHeaderName.TRANSFER_ENCODING => "transfer-encoding",
    HttpHeaderName.COOKIE => "cookie",
    HttpHeaderName.SET_COOKIE => "set-cookie",
    HttpHeaderName.HOST => "host",
    HttpHeaderName.CACHE_CONTROL => "cache-control",
    HttpHeaderName.MAX_FORWARDS => "max-forwards",
    HttpHeaderName.PRAGMA => "pragma",
    HttpHeaderName.RANGE => "range",
    HttpHeaderName.TE => "te",
    HttpHeaderName.CONTENT_ENCODING => "content-encoding",
    HttpHeaderName.CONTENT_TYPE => "content-type",
    HttpHeaderName.CONTENT_RANGE => "content-range",
    HttpHeaderName.TRAILER => "trailer",
    HttpHeaderName.WWW_AUTHENTICATE => "www-authenticate",
    HttpHeaderName.AUTHORIZATION => "authorization",
    HttpHeaderName.PROXY_AUTHENTICATE => "proxy-authenticate",
    HttpHeaderName.PROXY_AUTHORIZATION => "proxy-authorization",
    HttpHeaderName.AGE => "age",
    HttpHeaderName.EXPIRES => "expires",
    HttpHeaderName.DATE => "date",
    HttpHeaderName.LOCATION => "location",
    HttpHeaderName.RETRY_AFTER => "retry-after",
    HttpHeaderName.VARY => "vary",
    HttpHeaderName.WARNING => "warning",
    HttpHeaderName.UPGRADE => "upgrade",
    HttpHeaderName.KEEP_ALIVE => "keep-alive",
    HttpHeaderName.PROXY_CONNECTION => "proxy-connection",
)

# Case-insensitive lookup: lowercase key -> enum
const _HEADER_LOWERCASE_STR_TO_ENUM = Dict{String, HttpHeaderName.T}(
    v => k for (k, v) in _HEADER_ENUM_TO_STR
)

"""
    http_str_to_header_name(s::AbstractString) -> HttpHeaderName.T

Case-insensitive header name to enum lookup.
Returns `HttpHeaderName.UNKNOWN` for unrecognized headers.
"""
function http_str_to_header_name(s::AbstractString)::HttpHeaderName.T
    return get(_HEADER_LOWERCASE_STR_TO_ENUM, lowercase(s), HttpHeaderName.UNKNOWN)
end

"""
    http_lowercase_str_to_header_name(s::AbstractString) -> HttpHeaderName.T

Case-sensitive header name to enum lookup (input must already be lowercase).
Returns `HttpHeaderName.UNKNOWN` for unrecognized headers.
"""
function http_lowercase_str_to_header_name(s::AbstractString)::HttpHeaderName.T
    return get(_HEADER_LOWERCASE_STR_TO_ENUM, String(s), HttpHeaderName.UNKNOWN)
end

"""
    http_header_name_to_str(name::HttpHeaderName.T) -> String

Return the lowercase string for a known header name enum value.
Returns empty string for UNKNOWN.
"""
function http_header_name_to_str(name::HttpHeaderName.T)::String
    return get(_HEADER_ENUM_TO_STR, name, "")
end

# ─── Retryable error helper ───

"""
    http_error_code_is_retryable(error_code::Integer) -> Bool

Determine if an HTTP error code is retryable.
Falls through to `io_error_code_is_retryable` for IO-layer errors.
"""
function http_error_code_is_retryable(error_code::Integer)::Bool
    if error_code == ERROR_HTTP_CONNECTION_CLOSED ||
       error_code == ERROR_HTTP_SERVER_CLOSED ||
       error_code == ERROR_HTTP_PROXY_CONNECT_FAILED_RETRYABLE
        return true
    end
    return EventLoops.io_error_code_is_retryable(error_code)
end
