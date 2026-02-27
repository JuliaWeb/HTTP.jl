using Test
using AwsHTTP
using Reseau
using Base64

# ─── Phase 0: Core library, errors, logging, status codes ───

@testset "HTTP error codes" begin
    # Verify error codes are in the correct range
    begin_range = Reseau.ERROR_ENUM_BEGIN_RANGE(AwsHTTP.HTTP_PACKAGE_ID)
    end_range = Reseau.ERROR_ENUM_END_RANGE(AwsHTTP.HTTP_PACKAGE_ID)

    @test AwsHTTP.ERROR_HTTP_UNKNOWN == begin_range
    @test AwsHTTP.ERROR_HTTP_END_RANGE == end_range

    # Verify sequential ordering (no gaps)
    @test AwsHTTP.ERROR_HTTP_HEADER_NOT_FOUND == AwsHTTP.ERROR_HTTP_UNKNOWN + 1
    @test AwsHTTP.ERROR_HTTP_INVALID_HEADER_FIELD == AwsHTTP.ERROR_HTTP_UNKNOWN + 2
    @test AwsHTTP.ERROR_HTTP_INVALID_HEADER_NAME == AwsHTTP.ERROR_HTTP_UNKNOWN + 3
    @test AwsHTTP.ERROR_HTTP_INVALID_HEADER_VALUE == AwsHTTP.ERROR_HTTP_UNKNOWN + 4
    @test AwsHTTP.ERROR_HTTP_INVALID_METHOD == AwsHTTP.ERROR_HTTP_UNKNOWN + 5
    @test AwsHTTP.ERROR_HTTP_INVALID_PATH == AwsHTTP.ERROR_HTTP_UNKNOWN + 6
    @test AwsHTTP.ERROR_HTTP_INVALID_STATUS_CODE == AwsHTTP.ERROR_HTTP_UNKNOWN + 7
    @test AwsHTTP.ERROR_HTTP_MISSING_BODY_STREAM == AwsHTTP.ERROR_HTTP_UNKNOWN + 8
    @test AwsHTTP.ERROR_HTTP_INVALID_BODY_STREAM == AwsHTTP.ERROR_HTTP_UNKNOWN + 9
    @test AwsHTTP.ERROR_HTTP_CONNECTION_CLOSED == AwsHTTP.ERROR_HTTP_UNKNOWN + 10

    # Verify all 47 error codes have descriptions
    for code in AwsHTTP.ERROR_HTTP_UNKNOWN:AwsHTTP.ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED
        @test AwsHTTP.http_error_str(code) != "Unknown HTTP error"
        @test AwsHTTP.http_error_name(code) != "UNKNOWN"
    end

    # Verify total count of error codes matches C (47 named errors)
    count = AwsHTTP.ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED - AwsHTTP.ERROR_HTTP_UNKNOWN + 1
    @test count == 47

    # Verify all error codes fit within range
    @test AwsHTTP.ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED < AwsHTTP.ERROR_HTTP_END_RANGE
end

@testset "HTTP/2 error codes" begin
    # Verify all 14 HTTP/2 error codes
    @test UInt32(AwsHTTP.Http2ErrorCode.NO_ERROR) == 0x00
    @test UInt32(AwsHTTP.Http2ErrorCode.PROTOCOL_ERROR) == 0x01
    @test UInt32(AwsHTTP.Http2ErrorCode.INTERNAL_ERROR) == 0x02
    @test UInt32(AwsHTTP.Http2ErrorCode.FLOW_CONTROL_ERROR) == 0x03
    @test UInt32(AwsHTTP.Http2ErrorCode.SETTINGS_TIMEOUT) == 0x04
    @test UInt32(AwsHTTP.Http2ErrorCode.STREAM_CLOSED) == 0x05
    @test UInt32(AwsHTTP.Http2ErrorCode.FRAME_SIZE_ERROR) == 0x06
    @test UInt32(AwsHTTP.Http2ErrorCode.REFUSED_STREAM) == 0x07
    @test UInt32(AwsHTTP.Http2ErrorCode.CANCEL) == 0x08
    @test UInt32(AwsHTTP.Http2ErrorCode.COMPRESSION_ERROR) == 0x09
    @test UInt32(AwsHTTP.Http2ErrorCode.CONNECT_ERROR) == 0x0A
    @test UInt32(AwsHTTP.Http2ErrorCode.ENHANCE_YOUR_CALM) == 0x0B
    @test UInt32(AwsHTTP.Http2ErrorCode.INADEQUATE_SECURITY) == 0x0C
    @test UInt32(AwsHTTP.Http2ErrorCode.HTTP_1_1_REQUIRED) == 0x0D

    # String conversion
    @test AwsHTTP.http2_error_code_to_str(AwsHTTP.Http2ErrorCode.NO_ERROR) == "NO_ERROR"
    @test AwsHTTP.http2_error_code_to_str(AwsHTTP.Http2ErrorCode.PROTOCOL_ERROR) == "PROTOCOL_ERROR"
    @test AwsHTTP.http2_error_code_to_str(AwsHTTP.Http2ErrorCode.CANCEL) == "CANCEL"
    @test AwsHTTP.http2_error_code_to_str(AwsHTTP.Http2ErrorCode.HTTP_1_1_REQUIRED) == "HTTP_1_1_REQUIRED"
end

@testset "HTTP log subjects" begin
    begin_range = Reseau.LOG_SUBJECT_BEGIN_RANGE(AwsHTTP.HTTP_PACKAGE_ID)
    end_range = Reseau.LOG_SUBJECT_END_RANGE(AwsHTTP.HTTP_PACKAGE_ID)

    @test AwsHTTP.LS_HTTP_GENERAL == begin_range
    @test AwsHTTP.LS_HTTP_LAST == end_range

    # Verify sequential ordering
    @test AwsHTTP.LS_HTTP_CONNECTION == AwsHTTP.LS_HTTP_GENERAL + 1
    @test AwsHTTP.LS_HTTP_ENCODER == AwsHTTP.LS_HTTP_GENERAL + 2
    @test AwsHTTP.LS_HTTP_DECODER == AwsHTTP.LS_HTTP_GENERAL + 3
    @test AwsHTTP.LS_HTTP_SERVER == AwsHTTP.LS_HTTP_GENERAL + 4
    @test AwsHTTP.LS_HTTP_STREAM == AwsHTTP.LS_HTTP_GENERAL + 5
    @test AwsHTTP.LS_HTTP_CONNECTION_MANAGER == AwsHTTP.LS_HTTP_GENERAL + 6
    @test AwsHTTP.LS_HTTP_STREAM_MANAGER == AwsHTTP.LS_HTTP_GENERAL + 7
    @test AwsHTTP.LS_HTTP_WEBSOCKET == AwsHTTP.LS_HTTP_GENERAL + 8
    @test AwsHTTP.LS_HTTP_WEBSOCKET_SETUP == AwsHTTP.LS_HTTP_GENERAL + 9
    @test AwsHTTP.LS_HTTP_PROXY_NEGOTIATION == AwsHTTP.LS_HTTP_GENERAL + 10

    # All subjects fit within range
    @test AwsHTTP.LS_HTTP_PROXY_NEGOTIATION < AwsHTTP.LS_HTTP_LAST
end

@testset "HTTP version enum" begin
    @test UInt8(AwsHTTP.HttpVersion.UNKNOWN) == 0
    @test UInt8(AwsHTTP.HttpVersion.HTTP_1_0) == 1
    @test UInt8(AwsHTTP.HttpVersion.HTTP_1_1) == 2
    @test UInt8(AwsHTTP.HttpVersion.HTTP_2) == 3

    @test AwsHTTP.http_version_to_str(AwsHTTP.HttpVersion.UNKNOWN) == "Unknown"
    @test AwsHTTP.http_version_to_str(AwsHTTP.HttpVersion.HTTP_1_0) == "HTTP/1.0"
    @test AwsHTTP.http_version_to_str(AwsHTTP.HttpVersion.HTTP_1_1) == "HTTP/1.1"
    @test AwsHTTP.http_version_to_str(AwsHTTP.HttpVersion.HTTP_2) == "HTTP/2"
end

@testset "HTTP status codes" begin
    # Test all status code constants exist and have correct values
    @test AwsHTTP.HTTP_STATUS_CODE_UNKNOWN == -1
    @test AwsHTTP.HTTP_STATUS_CODE_200_OK == 200
    @test AwsHTTP.HTTP_STATUS_CODE_404_NOT_FOUND == 404
    @test AwsHTTP.HTTP_STATUS_CODE_500_INTERNAL_SERVER_ERROR == 500

    # Test status text for all categories
    @test AwsHTTP.http_status_text(100) == "Continue"
    @test AwsHTTP.http_status_text(101) == "Switching Protocols"
    @test AwsHTTP.http_status_text(102) == "Processing"
    @test AwsHTTP.http_status_text(103) == "Early Hints"
    @test AwsHTTP.http_status_text(200) == "OK"
    @test AwsHTTP.http_status_text(201) == "Created"
    @test AwsHTTP.http_status_text(202) == "Accepted"
    @test AwsHTTP.http_status_text(204) == "No Content"
    @test AwsHTTP.http_status_text(301) == "Moved Permanently"
    @test AwsHTTP.http_status_text(302) == "Found"
    @test AwsHTTP.http_status_text(304) == "Not Modified"
    @test AwsHTTP.http_status_text(307) == "Temporary Redirect"
    @test AwsHTTP.http_status_text(308) == "Permanent Redirect"
    @test AwsHTTP.http_status_text(400) == "Bad Request"
    @test AwsHTTP.http_status_text(401) == "Unauthorized"
    @test AwsHTTP.http_status_text(403) == "Forbidden"
    @test AwsHTTP.http_status_text(404) == "Not Found"
    @test AwsHTTP.http_status_text(405) == "Method Not Allowed"
    @test AwsHTTP.http_status_text(408) == "Request Timeout"
    @test AwsHTTP.http_status_text(409) == "Conflict"
    @test AwsHTTP.http_status_text(413) == "Payload Too Large"
    @test AwsHTTP.http_status_text(414) == "URI Too Long"
    @test AwsHTTP.http_status_text(416) == "Range Not Satisfiable"
    @test AwsHTTP.http_status_text(429) == "Too Many Requests"
    @test AwsHTTP.http_status_text(451) == "Unavailable For Legal Reasons"
    @test AwsHTTP.http_status_text(500) == "Internal Server Error"
    @test AwsHTTP.http_status_text(501) == "Not Implemented"
    @test AwsHTTP.http_status_text(502) == "Bad Gateway"
    @test AwsHTTP.http_status_text(503) == "Service Unavailable"
    @test AwsHTTP.http_status_text(504) == "Gateway Timeout"
    @test AwsHTTP.http_status_text(511) == "Network Authentication Required"

    # Unknown status code returns empty string
    @test AwsHTTP.http_status_text(0) == ""
    @test AwsHTTP.http_status_text(999) == ""
    @test AwsHTTP.http_status_text(-1) == ""

    # Verify total count matches C (61 status codes with text)
    count = length(AwsHTTP._STATUS_TEXT)
    @test count == 61
end

@testset "HTTP header name constants and lookup" begin
    # Pseudo-header strings
    @test AwsHTTP.HTTP_HEADER_METHOD_STR == ":method"
    @test AwsHTTP.HTTP_HEADER_SCHEME_STR == ":scheme"
    @test AwsHTTP.HTTP_HEADER_AUTHORITY_STR == ":authority"
    @test AwsHTTP.HTTP_HEADER_PATH_STR == ":path"
    @test AwsHTTP.HTTP_HEADER_STATUS_STR == ":status"

    # Scheme strings
    @test AwsHTTP.HTTP_SCHEME_HTTP == "http"
    @test AwsHTTP.HTTP_SCHEME_HTTPS == "https"

    # Case-insensitive lookup
    @test AwsHTTP.http_str_to_header_name(":method") == AwsHTTP.HttpHeaderName.METHOD
    @test AwsHTTP.http_str_to_header_name(":scheme") == AwsHTTP.HttpHeaderName.SCHEME
    @test AwsHTTP.http_str_to_header_name("content-length") == AwsHTTP.HttpHeaderName.CONTENT_LENGTH
    @test AwsHTTP.http_str_to_header_name("Content-Length") == AwsHTTP.HttpHeaderName.CONTENT_LENGTH
    @test AwsHTTP.http_str_to_header_name("CONTENT-LENGTH") == AwsHTTP.HttpHeaderName.CONTENT_LENGTH
    @test AwsHTTP.http_str_to_header_name("transfer-encoding") == AwsHTTP.HttpHeaderName.TRANSFER_ENCODING
    @test AwsHTTP.http_str_to_header_name("Transfer-Encoding") == AwsHTTP.HttpHeaderName.TRANSFER_ENCODING
    @test AwsHTTP.http_str_to_header_name("cookie") == AwsHTTP.HttpHeaderName.COOKIE
    @test AwsHTTP.http_str_to_header_name("host") == AwsHTTP.HttpHeaderName.HOST
    @test AwsHTTP.http_str_to_header_name("connection") == AwsHTTP.HttpHeaderName.CONNECTION
    @test AwsHTTP.http_str_to_header_name("upgrade") == AwsHTTP.HttpHeaderName.UPGRADE

    # Unknown headers
    @test AwsHTTP.http_str_to_header_name("x-custom-header") == AwsHTTP.HttpHeaderName.UNKNOWN
    @test AwsHTTP.http_str_to_header_name("") == AwsHTTP.HttpHeaderName.UNKNOWN

    # Case-sensitive (lowercase only) lookup
    @test AwsHTTP.http_lowercase_str_to_header_name("content-length") == AwsHTTP.HttpHeaderName.CONTENT_LENGTH
    @test AwsHTTP.http_lowercase_str_to_header_name("Content-Length") == AwsHTTP.HttpHeaderName.UNKNOWN  # not lowercase

    # All 35 known headers have string mappings
    for name_val in instances(AwsHTTP.HttpHeaderName.T)
        name_val == AwsHTTP.HttpHeaderName.UNKNOWN && continue
        str = AwsHTTP.http_header_name_to_str(name_val)
        @test !isempty(str)
        # Round-trip: str -> enum -> str
        @test AwsHTTP.http_str_to_header_name(str) == name_val
    end
end

@testset "HTTP retryable error helper" begin
    # HTTP-specific retryable errors
    @test AwsHTTP.http_error_code_is_retryable(AwsHTTP.ERROR_HTTP_CONNECTION_CLOSED) == true
    @test AwsHTTP.http_error_code_is_retryable(AwsHTTP.ERROR_HTTP_SERVER_CLOSED) == true
    @test AwsHTTP.http_error_code_is_retryable(AwsHTTP.ERROR_HTTP_PROXY_CONNECT_FAILED_RETRYABLE) == true

    # Non-retryable HTTP errors
    @test AwsHTTP.http_error_code_is_retryable(AwsHTTP.ERROR_HTTP_UNKNOWN) == false
    @test AwsHTTP.http_error_code_is_retryable(AwsHTTP.ERROR_HTTP_INVALID_METHOD) == false
    @test AwsHTTP.http_error_code_is_retryable(AwsHTTP.ERROR_HTTP_PROTOCOL_ERROR) == false

    # IO-layer retryable errors pass through
    @test AwsHTTP.http_error_code_is_retryable(Reseau.EventLoops.ERROR_IO_SOCKET_CLOSED) == true
    @test AwsHTTP.http_error_code_is_retryable(Reseau.EventLoops.ERROR_IO_SOCKET_CONNECTION_REFUSED) == true
end

# ─── Phase 1: HTTP headers and messages ───

@testset "HttpHeaderCompression enum" begin
    @test UInt8(AwsHTTP.HttpHeaderCompression.USE_CACHE) == 0
    @test UInt8(AwsHTTP.HttpHeaderCompression.NO_CACHE) == 1
    @test UInt8(AwsHTTP.HttpHeaderCompression.NO_FORWARD_CACHE) == 2
end

@testset "HttpHeaderBlock enum" begin
    @test UInt8(AwsHTTP.HttpHeaderBlock.MAIN) == 0
    @test UInt8(AwsHTTP.HttpHeaderBlock.INFORMATIONAL) == 1
    @test UInt8(AwsHTTP.HttpHeaderBlock.TRAILING) == 2
end

@testset "HttpHeader struct" begin
    h = AwsHTTP.HttpHeader("Content-Type", "text/html")
    @test h.name == "Content-Type"
    @test h.value == "text/html"
    @test h.compression == AwsHTTP.HttpHeaderCompression.USE_CACHE

    h2 = AwsHTTP.HttpHeader("X-Custom", "val", AwsHTTP.HttpHeaderCompression.NO_CACHE)
    @test h2.compression == AwsHTTP.HttpHeaderCompression.NO_CACHE
end

@testset "Utility functions" begin
    # Pseudo-header detection
    @test AwsHTTP.is_pseudo_header_name(":method") == true
    @test AwsHTTP.is_pseudo_header_name(":scheme") == true
    @test AwsHTTP.is_pseudo_header_name(":authority") == true
    @test AwsHTTP.is_pseudo_header_name(":path") == true
    @test AwsHTTP.is_pseudo_header_name(":status") == true
    @test AwsHTTP.is_pseudo_header_name("host") == false
    @test AwsHTTP.is_pseudo_header_name("") == false
    @test AwsHTTP.is_pseudo_header_name("content-type") == false

    # Case-insensitive name comparison
    @test AwsHTTP.http_header_name_eq("Content-Type", "content-type") == true
    @test AwsHTTP.http_header_name_eq("HOST", "host") == true
    @test AwsHTTP.http_header_name_eq("foo", "bar") == false

    # HTTP whitespace trimming
    @test AwsHTTP.trim_http_whitespace("  hello  ") == "hello"
    @test AwsHTTP.trim_http_whitespace("\thello\t") == "hello"
    @test AwsHTTP.trim_http_whitespace(" \t hello \t ") == "hello"
    @test AwsHTTP.trim_http_whitespace("hello") == "hello"
    @test AwsHTTP.trim_http_whitespace("") == ""
end

@testset "HttpHeaders creation and lifecycle" begin
    headers = AwsHTTP.http_headers_new()
    @test AwsHTTP.http_headers_count(headers) == 0

    AwsHTTP.http_headers_add(headers, "foo", "bar")
    @test AwsHTTP.http_headers_count(headers) == 1
end

@testset "HttpHeaders add and get" begin
    headers = AwsHTTP.http_headers_new()

    # Add headers
    @test AwsHTTP.http_headers_add(headers, "Content-Type", "text/html") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_headers_add(headers, "Content-Length", "42") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_headers_add(headers, "X-Custom", "value1") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_headers_count(headers) == 3

    # Get by name (case-insensitive)
    @test AwsHTTP.http_headers_get(headers, "content-type") == "text/html"
    @test AwsHTTP.http_headers_get(headers, "CONTENT-TYPE") == "text/html"
    @test AwsHTTP.http_headers_get(headers, "Content-Length") == "42"
    @test AwsHTTP.http_headers_get(headers, "x-custom") == "value1"

    # Get not found
    @test AwsHTTP.http_headers_get(headers, "x-missing") === nothing

    # Get by index (0-based)
    h0 = AwsHTTP.http_headers_get_index(headers, 0)
    @test h0 !== nothing
    @test h0.name == "Content-Type"
    @test h0.value == "text/html"

    h2 = AwsHTTP.http_headers_get_index(headers, 2)
    @test h2 !== nothing
    @test h2.name == "X-Custom"

    # Invalid index
    @test AwsHTTP.http_headers_get_index(headers, -1) === nothing
    @test AwsHTTP.http_headers_get_index(headers, 3) === nothing

    # Empty name is rejected
    @test AwsHTTP.http_headers_add(headers, "", "val") == Reseau.OP_ERR
    @test AwsHTTP.http_headers_count(headers) == 3  # unchanged
end

@testset "HttpHeaders value whitespace trimming" begin
    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, "X-Trimmed", "  hello world  ")
    @test AwsHTTP.http_headers_get(headers, "X-Trimmed") == "hello world"

    AwsHTTP.http_headers_add(headers, "X-Tabs", "\tvalue\t")
    @test AwsHTTP.http_headers_get(headers, "X-Tabs") == "value"
end

@testset "HttpHeaders has" begin
    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, "Host", "example.com")

    @test AwsHTTP.http_headers_has(headers, "Host") == true
    @test AwsHTTP.http_headers_has(headers, "host") == true
    @test AwsHTTP.http_headers_has(headers, "HOST") == true
    @test AwsHTTP.http_headers_has(headers, "missing") == false
end

@testset "HttpHeaders get_all" begin
    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, "Set-Cookie", "a=1")
    AwsHTTP.http_headers_add(headers, "Other", "middle")
    AwsHTTP.http_headers_add(headers, "Set-Cookie", "b=2")
    AwsHTTP.http_headers_add(headers, "Set-Cookie", "c=3")

    result = AwsHTTP.http_headers_get_all(headers, "Set-Cookie")
    @test result == "a=1, b=2, c=3"

    # Single value
    @test AwsHTTP.http_headers_get_all(headers, "Other") == "middle"

    # Not found
    @test AwsHTTP.http_headers_get_all(headers, "missing") === nothing
end

@testset "HttpHeaders add_array" begin
    headers = AwsHTTP.http_headers_new()
    arr = [
        AwsHTTP.HttpHeader("A", "1"),
        AwsHTTP.HttpHeader("B", "2"),
        AwsHTTP.HttpHeader("C", "3"),
    ]
    @test AwsHTTP.http_headers_add_array(headers, arr) == Reseau.OP_SUCCESS
    @test AwsHTTP.http_headers_count(headers) == 3
    @test AwsHTTP.http_headers_get(headers, "A") == "1"
    @test AwsHTTP.http_headers_get(headers, "B") == "2"
    @test AwsHTTP.http_headers_get(headers, "C") == "3"

    # Array with invalid entry rolls back
    headers2 = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers2, "existing", "val")
    bad_arr = [
        AwsHTTP.HttpHeader("D", "4"),
        AwsHTTP.HttpHeader("", "invalid"),  # empty name -> error
    ]
    @test AwsHTTP.http_headers_add_array(headers2, bad_arr) == Reseau.OP_ERR
    @test AwsHTTP.http_headers_count(headers2) == 1  # rolled back
    @test AwsHTTP.http_headers_get(headers2, "existing") == "val"
end

@testset "HttpHeaders set" begin
    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, "Host", "old.com")
    AwsHTTP.http_headers_add(headers, "Other", "keep")
    AwsHTTP.http_headers_add(headers, "Host", "old2.com")
    @test AwsHTTP.http_headers_count(headers) == 3

    # Set replaces all existing "Host" headers
    @test AwsHTTP.http_headers_set(headers, "Host", "new.com") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_headers_count(headers) == 2  # "Host" + "Other"
    @test AwsHTTP.http_headers_get(headers, "Host") == "new.com"
    @test AwsHTTP.http_headers_get(headers, "Other") == "keep"

    # Set a new header (no existing to replace)
    @test AwsHTTP.http_headers_set(headers, "New-Header", "value") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_headers_count(headers) == 3
    @test AwsHTTP.http_headers_get(headers, "New-Header") == "value"
end

@testset "HttpHeaders erase" begin
    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, "A", "1")
    AwsHTTP.http_headers_add(headers, "B", "2")
    AwsHTTP.http_headers_add(headers, "A", "3")
    AwsHTTP.http_headers_add(headers, "C", "4")
    @test AwsHTTP.http_headers_count(headers) == 4

    # Erase all "A" headers
    @test AwsHTTP.http_headers_erase(headers, "A") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_headers_count(headers) == 2
    @test AwsHTTP.http_headers_has(headers, "A") == false
    @test AwsHTTP.http_headers_get(headers, "B") == "2"
    @test AwsHTTP.http_headers_get(headers, "C") == "4"

    # Erase nonexistent
    @test AwsHTTP.http_headers_erase(headers, "A") == Reseau.OP_ERR
end

@testset "HttpHeaders erase_value" begin
    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, "X", "one")
    AwsHTTP.http_headers_add(headers, "X", "two")
    AwsHTTP.http_headers_add(headers, "X", "three")
    @test AwsHTTP.http_headers_count(headers) == 3

    # Erase specific value
    @test AwsHTTP.http_headers_erase_value(headers, "X", "two") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_headers_count(headers) == 2
    vals = AwsHTTP.http_headers_get_all(headers, "X")
    @test vals == "one, three"

    # Erase nonexistent value
    @test AwsHTTP.http_headers_erase_value(headers, "X", "two") == Reseau.OP_ERR  # already removed
    @test AwsHTTP.http_headers_erase_value(headers, "Y", "val") == Reseau.OP_ERR  # no such name
end

@testset "HttpHeaders erase_index" begin
    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, "A", "1")
    AwsHTTP.http_headers_add(headers, "B", "2")
    AwsHTTP.http_headers_add(headers, "C", "3")

    # Erase middle (0-based index 1)
    @test AwsHTTP.http_headers_erase_index(headers, 1) == Reseau.OP_SUCCESS
    @test AwsHTTP.http_headers_count(headers) == 2
    @test AwsHTTP.http_headers_get_index(headers, 0).name == "A"
    @test AwsHTTP.http_headers_get_index(headers, 1).name == "C"

    # Invalid index
    @test AwsHTTP.http_headers_erase_index(headers, -1) == Reseau.OP_ERR
    @test AwsHTTP.http_headers_erase_index(headers, 2) == Reseau.OP_ERR
end

@testset "HttpHeaders clear" begin
    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, "A", "1")
    AwsHTTP.http_headers_add(headers, "B", "2")
    @test AwsHTTP.http_headers_count(headers) == 2

    AwsHTTP.http_headers_clear(headers)
    @test AwsHTTP.http_headers_count(headers) == 0
    @test AwsHTTP.http_headers_has(headers, "A") == false
end

@testset "HttpHeaders pseudo-header ordering" begin
    headers = AwsHTTP.http_headers_new()

    # Add regular headers first
    AwsHTTP.http_headers_add(headers, "Host", "example.com")
    AwsHTTP.http_headers_add(headers, "Accept", "text/html")

    # Adding pseudo-header should go to front
    AwsHTTP.http_headers_add(headers, ":method", "GET")
    @test AwsHTTP.http_headers_count(headers) == 3
    @test AwsHTTP.http_headers_get_index(headers, 0).name == ":method"
    @test AwsHTTP.http_headers_get_index(headers, 1).name == "Host"
    @test AwsHTTP.http_headers_get_index(headers, 2).name == "Accept"

    # Adding another pseudo-header also goes to front
    AwsHTTP.http_headers_add(headers, ":scheme", "https")
    @test AwsHTTP.http_headers_get_index(headers, 0).name == ":scheme"
    @test AwsHTTP.http_headers_get_index(headers, 1).name == ":method"

    # When only pseudo-headers exist, new ones append to end
    headers2 = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers2, ":method", "GET")
    AwsHTTP.http_headers_add(headers2, ":path", "/")
    @test AwsHTTP.http_headers_get_index(headers2, 0).name == ":method"
    @test AwsHTTP.http_headers_get_index(headers2, 1).name == ":path"
end

@testset "H2 pseudo-header accessors" begin
    headers = AwsHTTP.http_headers_new()

    # Set and get request pseudo-headers
    @test AwsHTTP.http2_headers_set_request_method(headers, "GET") == Reseau.OP_SUCCESS
    @test AwsHTTP.http2_headers_get_request_method(headers) == "GET"

    @test AwsHTTP.http2_headers_set_request_scheme(headers, "https") == Reseau.OP_SUCCESS
    @test AwsHTTP.http2_headers_get_request_scheme(headers) == "https"

    @test AwsHTTP.http2_headers_set_request_authority(headers, "example.com") == Reseau.OP_SUCCESS
    @test AwsHTTP.http2_headers_get_request_authority(headers) == "example.com"

    @test AwsHTTP.http2_headers_set_request_path(headers, "/index.html") == Reseau.OP_SUCCESS
    @test AwsHTTP.http2_headers_get_request_path(headers) == "/index.html"

    # Overwrite existing
    @test AwsHTTP.http2_headers_set_request_method(headers, "POST") == Reseau.OP_SUCCESS
    @test AwsHTTP.http2_headers_get_request_method(headers) == "POST"

    # Response status
    headers2 = AwsHTTP.http_headers_new()
    @test AwsHTTP.http2_headers_set_response_status(headers2, 200) == Reseau.OP_SUCCESS
    @test AwsHTTP.http2_headers_get_response_status(headers2) == 200

    @test AwsHTTP.http2_headers_set_response_status(headers2, 404) == Reseau.OP_SUCCESS
    @test AwsHTTP.http2_headers_get_response_status(headers2) == 404

    # Status padded to 3 digits
    @test AwsHTTP.http2_headers_set_response_status(headers2, 1) == Reseau.OP_SUCCESS
    @test AwsHTTP.http_headers_get(headers2, ":status") == "001"
    @test AwsHTTP.http2_headers_get_response_status(headers2) == 1

    # Invalid status
    @test AwsHTTP.http2_headers_set_response_status(headers2, -1) == Reseau.OP_ERR
    @test AwsHTTP.http2_headers_set_response_status(headers2, 1000) == Reseau.OP_ERR
end

@testset "Http2PrioritySettings" begin
    p = AwsHTTP.Http2PrioritySettings()
    @test p.stream_dependency == 0
    @test p.stream_dependency_exclusive == false
    @test p.weight == 16

    p2 = AwsHTTP.Http2PrioritySettings(UInt32(5), true, UInt16(256))
    @test p2.stream_dependency == 5
    @test p2.stream_dependency_exclusive == true
    @test p2.weight == 256
end

@testset "HttpStreamMetrics" begin
    m = AwsHTTP.HttpStreamMetrics()
    @test m.send_start_timestamp_ns == -1
    @test m.send_end_timestamp_ns == -1
    @test m.sending_duration_ns == -1
    @test m.receive_start_timestamp_ns == -1
    @test m.receive_end_timestamp_ns == -1
    @test m.receiving_duration_ns == -1
    @test m.stream_id == 0

    m2 = AwsHTTP.HttpStreamMetrics(100, 200, 100, 300, 400, 100, UInt32(1))
    @test m2.send_start_timestamp_ns == 100
    @test m2.sending_duration_ns == 100
    @test m2.stream_id == 1
end

@testset "HttpMessage request creation" begin
    req = AwsHTTP.http_message_new_request()
    @test AwsHTTP.http_message_is_request(req) == true
    @test AwsHTTP.http_message_is_response(req) == false
    @test AwsHTTP.http_message_get_protocol_version(req) == AwsHTTP.HttpVersion.HTTP_1_1
    @test AwsHTTP.http_message_get_header_count(req) == 0
    @test AwsHTTP.http_message_get_body_stream(req) === nothing

    # Method not set initially
    @test AwsHTTP.http_message_get_request_method(req) === nothing
    @test AwsHTTP.http_message_get_request_path(req) === nothing
end

@testset "HttpMessage response creation" begin
    resp = AwsHTTP.http_message_new_response()
    @test AwsHTTP.http_message_is_request(resp) == false
    @test AwsHTTP.http_message_is_response(resp) == true
    @test AwsHTTP.http_message_get_protocol_version(resp) == AwsHTTP.HttpVersion.HTTP_1_1
    @test AwsHTTP.http_message_get_response_status(resp) === nothing  # not set
end

@testset "HttpMessage request with headers" begin
    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, "Host", "example.com")
    AwsHTTP.http_headers_add(headers, "Accept", "text/html")

    req = AwsHTTP.http_message_new_request_with_headers(headers)
    @test AwsHTTP.http_message_get_header_count(req) == 2
    @test AwsHTTP.http_headers_get(AwsHTTP.http_message_get_headers(req), "Host") == "example.com"
end

@testset "HttpMessage H1 request method/path" begin
    req = AwsHTTP.http_message_new_request()

    # Set and get method
    @test AwsHTTP.http_message_set_request_method(req, "GET") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_request_method(req) == "GET"

    # Overwrite method
    @test AwsHTTP.http_message_set_request_method(req, "POST") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_request_method(req) == "POST"

    # Set and get path
    @test AwsHTTP.http_message_set_request_path(req, "/api/v1") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_request_path(req) == "/api/v1"

    # Cannot get request fields from response
    resp = AwsHTTP.http_message_new_response()
    @test AwsHTTP.http_message_get_request_method(resp) === nothing
    @test AwsHTTP.http_message_get_request_path(resp) === nothing
    @test AwsHTTP.http_message_set_request_method(resp, "GET") == Reseau.OP_ERR
end

@testset "HttpMessage H1 response status" begin
    resp = AwsHTTP.http_message_new_response()

    @test AwsHTTP.http_message_set_response_status(resp, 200) == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_response_status(resp) == 200

    @test AwsHTTP.http_message_set_response_status(resp, 404) == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_response_status(resp) == 404

    # Invalid status codes
    @test AwsHTTP.http_message_set_response_status(resp, -1) == Reseau.OP_ERR
    @test AwsHTTP.http_message_set_response_status(resp, 1000) == Reseau.OP_ERR

    # Cannot set response status on request
    req = AwsHTTP.http_message_new_request()
    @test AwsHTTP.http_message_set_response_status(req, 200) == Reseau.OP_ERR
    @test AwsHTTP.http_message_get_response_status(req) === nothing
end

@testset "HttpMessage H2 request method/path via pseudo-headers" begin
    req = AwsHTTP.http2_message_new_request()
    @test AwsHTTP.http_message_get_protocol_version(req) == AwsHTTP.HttpVersion.HTTP_2

    @test AwsHTTP.http_message_set_request_method(req, "GET") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_request_method(req) == "GET"
    # Stored as :method pseudo-header
    @test AwsHTTP.http_headers_get(AwsHTTP.http_message_get_headers(req), ":method") == "GET"

    @test AwsHTTP.http_message_set_request_path(req, "/index.html") == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_request_path(req) == "/index.html"
    @test AwsHTTP.http_headers_get(AwsHTTP.http_message_get_headers(req), ":path") == "/index.html"
end

@testset "HttpMessage H2 response status via pseudo-headers" begin
    resp = AwsHTTP.http2_message_new_response()
    @test AwsHTTP.http_message_get_protocol_version(resp) == AwsHTTP.HttpVersion.HTTP_2

    @test AwsHTTP.http_message_set_response_status(resp, 200) == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_response_status(resp) == 200
    @test AwsHTTP.http_headers_get(AwsHTTP.http_message_get_headers(resp), ":status") == "200"
end

@testset "HttpMessage body stream" begin
    req = AwsHTTP.http_message_new_request()
    @test AwsHTTP.http_message_get_body_stream(req) === nothing

    body = IOBuffer("hello world")
    AwsHTTP.http_message_set_body_stream(req, body)
    @test AwsHTTP.http_message_get_body_stream(req) === body

    AwsHTTP.http_message_set_body_stream(req, nothing)
    @test AwsHTTP.http_message_get_body_stream(req) === nothing
end

@testset "HttpMessage convenience header methods" begin
    req = AwsHTTP.http_message_new_request()

    @test AwsHTTP.http_message_add_header(req, AwsHTTP.HttpHeader("A", "1")) == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_add_header(req, AwsHTTP.HttpHeader("B", "2")) == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_header_count(req) == 2

    h = AwsHTTP.http_message_get_header(req, 0)
    @test h !== nothing
    @test h.name == "A"
    @test h.value == "1"

    @test AwsHTTP.http_message_erase_header(req, 0) == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_header_count(req) == 1
    @test AwsHTTP.http_message_get_header(req, 0).name == "B"

    arr = [AwsHTTP.HttpHeader("C", "3"), AwsHTTP.HttpHeader("D", "4")]
    @test AwsHTTP.http_message_add_header_array(req, arr) == Reseau.OP_SUCCESS
    @test AwsHTTP.http_message_get_header_count(req) == 3
end

@testset "HttpMessage lifecycle" begin
    msg = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_add_header(msg, AwsHTTP.HttpHeader("X", "Y"))
    @test AwsHTTP.http_message_get_header_count(msg) == 1
    @test AwsHTTP.http_message_get_body_stream(msg) === nothing
end

@testset "H1→H2 request conversion" begin
    h1_req = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(h1_req, "GET")
    AwsHTTP.http_message_set_request_path(h1_req, "/index.html")
    AwsHTTP.http_message_add_header(h1_req, AwsHTTP.HttpHeader("Host", "example.com"))
    AwsHTTP.http_message_add_header(h1_req, AwsHTTP.HttpHeader("Accept", "text/html"))
    AwsHTTP.http_message_add_header(h1_req, AwsHTTP.HttpHeader("Connection", "keep-alive"))
    AwsHTTP.http_message_add_header(h1_req, AwsHTTP.HttpHeader("Keep-Alive", "timeout=5"))

    h2_req = AwsHTTP.http2_message_new_from_http1(h1_req)
    @test h2_req !== nothing
    @test AwsHTTP.http_message_is_request(h2_req) == true
    @test AwsHTTP.http_message_get_protocol_version(h2_req) == AwsHTTP.HttpVersion.HTTP_2

    headers = AwsHTTP.http_message_get_headers(h2_req)

    # Pseudo-headers present
    @test AwsHTTP.http_headers_get(headers, ":method") == "GET"
    @test AwsHTTP.http_headers_get(headers, ":scheme") == "https"
    @test AwsHTTP.http_headers_get(headers, ":authority") == "example.com"
    @test AwsHTTP.http_headers_get(headers, ":path") == "/index.html"

    # Regular header preserved (lowercased)
    @test AwsHTTP.http_headers_get(headers, "accept") == "text/html"

    # Connection-specific headers removed
    @test AwsHTTP.http_headers_has(headers, "connection") == false
    @test AwsHTTP.http_headers_has(headers, "keep-alive") == false
    @test AwsHTTP.http_headers_has(headers, "host") == false
end

@testset "H1→H2 request conversion parses absolute-form authority" begin
    h1_req = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(h1_req, "GET")
    AwsHTTP.http_message_set_request_path(h1_req, "http://example.com?x=1")

    h2_req = AwsHTTP.http2_message_new_from_http1(h1_req)
    @test h2_req !== nothing
    headers = AwsHTTP.http_message_get_headers(h2_req)
    @test AwsHTTP.http_headers_get(headers, ":authority") == "example.com"
    @test AwsHTTP.http_headers_get(headers, ":path") == "http://example.com?x=1"

    h1_req2 = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(h1_req2, "GET")
    AwsHTTP.http_message_set_request_path(h1_req2, "http://user:pass@[2001:db8::1]:8080?x=1")

    h2_req2 = AwsHTTP.http2_message_new_from_http1(h1_req2)
    @test h2_req2 !== nothing
    headers2 = AwsHTTP.http_message_get_headers(h2_req2)
    @test AwsHTTP.http_headers_get(headers2, ":authority") == "user:pass@[2001:db8::1]:8080"
end

@testset "H1→H2 request conversion with scheme override" begin
    h1_req = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(h1_req, "GET")
    AwsHTTP.http_message_set_request_path(h1_req, "/")
    AwsHTTP.http_message_add_header(h1_req, AwsHTTP.HttpHeader("Host", "example.com"))

    h2_req = AwsHTTP.http2_message_new_from_http1_with_scheme(h1_req, "http")
    @test h2_req !== nothing
    @test AwsHTTP.http_headers_get(AwsHTTP.http_message_get_headers(h2_req), ":scheme") == "http"
end

@testset "H1→H2 response conversion" begin
    h1_resp = AwsHTTP.http_message_new_response()
    AwsHTTP.http_message_set_response_status(h1_resp, 200)
    AwsHTTP.http_message_add_header(h1_resp, AwsHTTP.HttpHeader("Content-Type", "text/html"))
    AwsHTTP.http_message_add_header(h1_resp, AwsHTTP.HttpHeader("Connection", "close"))
    AwsHTTP.http_message_add_header(h1_resp, AwsHTTP.HttpHeader("Transfer-Encoding", "chunked"))

    h2_resp = AwsHTTP.http2_message_new_from_http1(h1_resp)
    @test h2_resp !== nothing
    @test AwsHTTP.http_message_is_response(h2_resp) == true

    headers = AwsHTTP.http_message_get_headers(h2_resp)
    @test AwsHTTP.http2_headers_get_response_status(headers) == 200
    @test AwsHTTP.http_headers_get(headers, "content-type") == "text/html"

    # Connection-specific removed
    @test AwsHTTP.http_headers_has(headers, "connection") == false
    @test AwsHTTP.http_headers_has(headers, "transfer-encoding") == false
end

@testset "H1→H2 conversion preserves TE: trailers" begin
    h1_req = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(h1_req, "GET")
    AwsHTTP.http_message_set_request_path(h1_req, "/")
    AwsHTTP.http_message_add_header(h1_req, AwsHTTP.HttpHeader("Host", "example.com"))
    AwsHTTP.http_message_add_header(h1_req, AwsHTTP.HttpHeader("TE", "trailers"))

    h2_req = AwsHTTP.http2_message_new_from_http1(h1_req)
    @test h2_req !== nothing
    @test AwsHTTP.http_headers_get(AwsHTTP.http_message_get_headers(h2_req), "te") == "trailers"
end

@testset "H1→H2 conversion body stream" begin
    h1_req = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(h1_req, "POST")
    AwsHTTP.http_message_set_request_path(h1_req, "/upload")
    AwsHTTP.http_message_add_header(h1_req, AwsHTTP.HttpHeader("Host", "example.com"))
    body = IOBuffer("request body")
    AwsHTTP.http_message_set_body_stream(h1_req, body)

    h2_req = AwsHTTP.http2_message_new_from_http1(h1_req)
    @test h2_req !== nothing
    @test AwsHTTP.http_message_get_body_stream(h2_req) === body
end

# ─── Phase 2: HTTP/1.1 encoder ───

# Helper: create an IOBuffer with a max size for encoder output
function make_output_buf(maxsize::Int=16384)
    buf = IOBuffer(maxsize=maxsize)
    return buf
end

# Helper: encode a full message and return the encoded bytes as a string
function encode_message_to_string(encoder, encoder_msg)
    buf = make_output_buf()
    AwsHTTP.h1_encoder_start_message!(encoder, encoder_msg)
    @test AwsHTTP.h1_encoder_process!(encoder, buf) == Reseau.OP_SUCCESS
    return String(take!(buf))
end

@testset "HTTP string validation - is_http_token" begin
    # Valid tokens
    @test AwsHTTP.is_http_token("GET") == true
    @test AwsHTTP.is_http_token("Content-Type") == true
    @test AwsHTTP.is_http_token("X-Custom-Header") == true
    @test AwsHTTP.is_http_token("accept") == true
    @test AwsHTTP.is_http_token("host") == true
    @test AwsHTTP.is_http_token("!#\$%&'*+-.^_`|~") == true  # all special tchar
    @test AwsHTTP.is_http_token("abc123") == true

    # Invalid tokens
    @test AwsHTTP.is_http_token("") == false              # empty
    @test AwsHTTP.is_http_token("G@T") == false            # @ is not tchar
    @test AwsHTTP.is_http_token("Host:") == false          # colon is not tchar
    @test AwsHTTP.is_http_token("name value") == false     # space is not tchar
    @test AwsHTTP.is_http_token("Line-\r\n-Folds") == false # CR/LF not tchar
    @test AwsHTTP.is_http_token("bad\x00name") == false    # null byte
    @test AwsHTTP.is_http_token("(parens)") == false       # parens not tchar
    @test AwsHTTP.is_http_token("a/b") == false            # slash not tchar
end

@testset "HTTP string validation - is_http_field_value" begin
    # Valid field values
    @test AwsHTTP.is_http_field_value("") == true           # empty is valid
    @test AwsHTTP.is_http_field_value("text/html") == true
    @test AwsHTTP.is_http_field_value("hello world") == true  # SP allowed in middle
    @test AwsHTTP.is_http_field_value("a\tb") == true         # HTAB allowed in middle
    @test AwsHTTP.is_http_field_value("value") == true
    @test AwsHTTP.is_http_field_value("application/json; charset=utf-8") == true

    # Invalid field values
    @test AwsHTTP.is_http_field_value(" leading") == false   # leading SP
    @test AwsHTTP.is_http_field_value("trailing ") == false  # trailing SP
    @test AwsHTTP.is_http_field_value("\tleading") == false   # leading HTAB
    @test AwsHTTP.is_http_field_value("trailing\t") == false  # trailing HTAB
    @test AwsHTTP.is_http_field_value("bad\r\nvalue") == false  # CR/LF
    @test AwsHTTP.is_http_field_value("bad\x00value") == false  # null byte
    @test AwsHTTP.is_http_field_value("item1,\r\n item2") == false  # obs-fold
end

@testset "HTTP string validation - is_http_request_target" begin
    # Valid request targets
    @test AwsHTTP.is_http_request_target("/") == true
    @test AwsHTTP.is_http_request_target("/index.html") == true
    @test AwsHTTP.is_http_request_target("/api/v1/users?page=1") == true
    @test AwsHTTP.is_http_request_target("*") == true
    @test AwsHTTP.is_http_request_target("http://example.com/path") == true

    # Invalid request targets
    @test AwsHTTP.is_http_request_target("") == false         # empty
    @test AwsHTTP.is_http_request_target("/\r\n/index.html") == false  # CR/LF
    @test AwsHTTP.is_http_request_target("/ /path") == false  # space
    @test AwsHTTP.is_http_request_target("/\x00") == false     # null byte
end

@testset "H1DecodedHeader struct" begin
    h = AwsHTTP.H1DecodedHeader(AwsHTTP.HttpHeaderName.HOST, "Host", "example.com", "Host: example.com")
    @test h.name == AwsHTTP.HttpHeaderName.HOST
    @test h.name_data == "Host"
    @test h.value_data == "example.com"
    @test h.data == "Host: example.com"
end

@testset "ALPN map - default mappings" begin
    m = AwsHTTP.http_alpn_map_init()
    @test AwsHTTP.http_alpn_map_get(m, "h2") == AwsHTTP.HttpVersion.HTTP_2
    @test AwsHTTP.http_alpn_map_get(m, "http/1.1") == AwsHTTP.HttpVersion.HTTP_1_1
    @test AwsHTTP.http_alpn_map_get(m, "unknown") == AwsHTTP.HttpVersion.UNKNOWN
end

@testset "ALPN map - add and copy" begin
    m = AwsHTTP.http_alpn_map_init()
    AwsHTTP.http_alpn_map_add!(m, "custom", AwsHTTP.HttpVersion.HTTP_1_0)
    @test AwsHTTP.http_alpn_map_get(m, "custom") == AwsHTTP.HttpVersion.HTTP_1_0

    m2 = AwsHTTP.http_alpn_map_init_copy(m)
    @test AwsHTTP.http_alpn_map_get(m2, "custom") == AwsHTTP.HttpVersion.HTTP_1_0
    @test AwsHTTP.http_alpn_map_get(m2, "h2") == AwsHTTP.HttpVersion.HTTP_2

    # Modifying copy doesn't affect original
    AwsHTTP.http_alpn_map_add!(m2, "h2", AwsHTTP.HttpVersion.UNKNOWN)
    @test AwsHTTP.http_alpn_map_get(m, "h2") == AwsHTTP.HttpVersion.HTTP_2
    @test AwsHTTP.http_alpn_map_get(m2, "h2") == AwsHTTP.HttpVersion.UNKNOWN
end

# ── Switching protocols ──

@testset "Huffman - encode/decode roundtrip" begin
    for s in ["", "hello", "www.example.com", "no-cache", "custom-key", "custom-value"]
        data = Vector{UInt8}(codeunits(s))
        encoded = AwsHTTP.hpack_huffman_encode(data)
        status, decoded = AwsHTTP.hpack_huffman_decode(encoded)
        @test status == Reseau.OP_SUCCESS
        @test decoded == data
    end
end

@testset "Huffman - RFC 7541 C.4.1 www.example.com" begin
    # From RFC 7541 §C.4.1: Huffman encoding of "www.example.com"
    expected = UInt8[0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff]
    data = Vector{UInt8}(codeunits("www.example.com"))
    encoded = AwsHTTP.hpack_huffman_encode(data)
    @test encoded == expected

    status, decoded = AwsHTTP.hpack_huffman_decode(expected)
    @test status == Reseau.OP_SUCCESS
    @test String(decoded) == "www.example.com"
end

@testset "Huffman - encoded length" begin
    data = Vector{UInt8}(codeunits("www.example.com"))
    @test AwsHTTP.hpack_huffman_encoded_length(data) == 12
end

@testset "Huffman - all byte values roundtrip" begin
    data = UInt8.(0:255)
    encoded = AwsHTTP.hpack_huffman_encode(data)
    status, decoded = AwsHTTP.hpack_huffman_decode(encoded)
    @test status == Reseau.OP_SUCCESS
    @test decoded == data
end

# ── Integer encoding/decoding ──

@testset "HPACK integer - encode RFC 7541 C.1.1 (10 in 5-bit)" begin
    result = AwsHTTP.hpack_encode_integer(UInt64(10), UInt8(0), UInt8(5))
    @test result == UInt8[10]
end

@testset "HPACK integer - encode RFC 7541 C.1.2 (1337 in 5-bit)" begin
    result = AwsHTTP.hpack_encode_integer(UInt64(1337), UInt8(0), UInt8(5))
    @test result == UInt8[31, 154, 10]
end

@testset "HPACK integer - encode 42 in 8-bit prefix" begin
    result = AwsHTTP.hpack_encode_integer(UInt64(42), UInt8(0), UInt8(8))
    @test result == UInt8[42]
end

@testset "HPACK integer - encode 63 in 6-bit prefix" begin
    result = AwsHTTP.hpack_encode_integer(UInt64(63), UInt8(0), UInt8(6))
    @test result == UInt8[63, 0]
end

@testset "HPACK integer - decode 5-bit prefix (10)" begin
    dec = AwsHTTP.HpackIntegerDecoder()
    data = UInt8[10]
    pos = Ref(1)
    status, value, complete = AwsHTTP.hpack_decode_integer!(dec, data, pos, UInt8(5))
    @test status == Reseau.OP_SUCCESS
    @test complete == true
    @test value == 10
    @test pos[] == 2
end

@testset "HPACK integer - decode 6-bit prefix (63)" begin
    dec = AwsHTTP.HpackIntegerDecoder()
    data = UInt8[63, 0]
    pos = Ref(1)
    status, value, complete = AwsHTTP.hpack_decode_integer!(dec, data, pos, UInt8(6))
    @test status == Reseau.OP_SUCCESS
    @test complete == true
    @test value == 63
end

@testset "HPACK integer - decode 8-bit prefix (42)" begin
    dec = AwsHTTP.HpackIntegerDecoder()
    data = UInt8[42]
    pos = Ref(1)
    status, value, complete = AwsHTTP.hpack_decode_integer!(dec, data, pos, UInt8(8))
    @test status == Reseau.OP_SUCCESS
    @test complete == true
    @test value == 42
end

@testset "HPACK integer - decode 5-bit prefix (1337)" begin
    dec = AwsHTTP.HpackIntegerDecoder()
    data = UInt8[31, 154, 10]
    pos = Ref(1)
    status, value, complete = AwsHTTP.hpack_decode_integer!(dec, data, pos, UInt8(5))
    @test status == Reseau.OP_SUCCESS
    @test complete == true
    @test value == 1337
end

@testset "HPACK integer - decode incomplete" begin
    dec = AwsHTTP.HpackIntegerDecoder()
    data = UInt8[31, 0xff]  # prefix filled, continuation byte with high bit set
    pos = Ref(1)
    status, value, complete = AwsHTTP.hpack_decode_integer!(dec, data, pos, UInt8(5))
    @test status == Reseau.OP_SUCCESS
    @test complete == false
end

@testset "HPACK integer - decode overflow" begin
    dec = AwsHTTP.HpackIntegerDecoder()
    # Prefix full + 10 continuation bytes all 0xff = overflow
    data = UInt8[31, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    pos = Ref(1)
    status, value, complete = AwsHTTP.hpack_decode_integer!(dec, data, pos, UInt8(5))
    @test status != Reseau.OP_SUCCESS
end

@testset "HPACK integer - decode few in a row" begin
    dec = AwsHTTP.HpackIntegerDecoder()
    data = UInt8[10, 42, 63, 0, 31, 154, 10, 10]
    expected = [(UInt8(5), UInt64(10)), (UInt8(8), UInt64(42)), (UInt8(6), UInt64(63)),
                (UInt8(5), UInt64(1337)), (UInt8(5), UInt64(10))]
    pos = Ref(1)
    for (prefix, exp_val) in expected
        AwsHTTP._hpack_integer_decoder_reset!(dec)
        status, value, complete = AwsHTTP.hpack_decode_integer!(dec, data, pos, prefix)
        @test status == Reseau.OP_SUCCESS
        @test complete == true
        @test value == exp_val
    end
    @test pos[] == length(data) + 1
end

# ── String encoding/decoding ──

@testset "HPACK string - decode blank" begin
    dec = AwsHTTP.HpackStringDecoder()
    data = UInt8[0]  # length=0, no Huffman
    pos = Ref(1)
    status, output, complete = AwsHTTP.hpack_decode_string!(dec, data, pos)
    @test status == Reseau.OP_SUCCESS
    @test complete == true
    @test isempty(output)
end

@testset "HPACK string - decode uncompressed" begin
    dec = AwsHTTP.HpackStringDecoder()
    data = UInt8[5, UInt8('h'), UInt8('e'), UInt8('l'), UInt8('l'), UInt8('o')]
    pos = Ref(1)
    status, output, complete = AwsHTTP.hpack_decode_string!(dec, data, pos)
    @test status == Reseau.OP_SUCCESS
    @test complete == true
    @test String(output) == "hello"
end

@testset "HPACK string - decode Huffman (www.example.com)" begin
    dec = AwsHTTP.HpackStringDecoder()
    # 0x8c = 10001100: Huffman flag + length 12
    data = UInt8[0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff]
    pos = Ref(1)
    status, output, complete = AwsHTTP.hpack_decode_string!(dec, data, pos)
    @test status == Reseau.OP_SUCCESS
    @test complete == true
    @test String(output) == "www.example.com"
end

@testset "HPACK string - decode too large" begin
    dec = AwsHTTP.HpackStringDecoder()
    data = UInt8[5, UInt8('h'), UInt8('e'), UInt8('l'), UInt8('l'), UInt8('o')]
    pos = Ref(1)
    status, output, complete = AwsHTTP.hpack_decode_string!(dec, data, pos; max_length=4)
    @test status != Reseau.OP_SUCCESS
end

@testset "HPACK string - encode roundtrip" begin
    for s in ["", "hello", "www.example.com", "custom-key"]
        encoded = AwsHTTP.hpack_encode_string(s; huffman_mode=AwsHTTP.HpackHuffmanMode.NEVER)
        dec = AwsHTTP.HpackStringDecoder()
        pos = Ref(1)
        status, output, complete = AwsHTTP.hpack_decode_string!(dec, encoded, pos)
        @test status == Reseau.OP_SUCCESS
        @test complete == true
        @test String(output) == s
    end
end

@testset "HPACK string - encode Huffman roundtrip" begin
    for s in ["", "hello", "www.example.com", ":method"]
        encoded = AwsHTTP.hpack_encode_string(s; huffman_mode=AwsHTTP.HpackHuffmanMode.ALWAYS)
        dec = AwsHTTP.HpackStringDecoder()
        pos = Ref(1)
        status, output, complete = AwsHTTP.hpack_decode_string!(dec, encoded, pos)
        @test status == Reseau.OP_SUCCESS
        @test complete == true
        @test String(output) == s
    end
end

# ── Static table ──

@testset "HPACK static table - get" begin
    ctx = AwsHTTP.HpackContext()

    # Index 1: :authority (no value)
    h = AwsHTTP.hpack_get_header(ctx, 1)
    @test h !== nothing
    @test h[1] == ":authority"
    @test h[2] == ""

    # Index 5: :path /index.html
    h = AwsHTTP.hpack_get_header(ctx, 5)
    @test h !== nothing
    @test h[1] == ":path"
    @test h[2] == "/index.html"

    # Index 21: age (no value)
    h = AwsHTTP.hpack_get_header(ctx, 21)
    @test h !== nothing
    @test h[1] == "age"
    @test h[2] == ""

    # Out of range
    @test AwsHTTP.hpack_get_header(ctx, 0) === nothing
    @test AwsHTTP.hpack_get_header(ctx, 69) === nothing
end

@testset "HPACK static table - find" begin
    ctx = AwsHTTP.HpackContext()

    # Exact match: :method GET = index 2
    idx, has_val = AwsHTTP.hpack_find_index(ctx, ":method", "GET")
    @test idx == 2
    @test has_val == true

    # Name match only: :method TEAPOT -> index 2, no value match
    idx, has_val = AwsHTTP.hpack_find_index(ctx, ":method", "TEAPOT")
    @test idx == 2
    @test has_val == false

    # Exact match: :authority with empty value = index 1 (name-only)
    idx, has_val = AwsHTTP.hpack_find_index(ctx, ":authority", "amazon.com")
    @test idx == 1
    @test has_val == false

    # Not found
    idx, has_val = AwsHTTP.hpack_find_index(ctx, "garbage", "value")
    @test idx == 0
    @test has_val == false
end

# ── Dynamic table ──

@testset "HPACK dynamic table - insert and find" begin
    ctx = AwsHTTP.HpackContext()

    AwsHTTP.hpack_insert_header!(ctx, "herp", "derp")
    idx, has_val = AwsHTTP.hpack_find_index(ctx, "herp", "derp")
    @test idx == 62
    @test has_val == true

    # Name-only match
    idx, has_val = AwsHTTP.hpack_find_index(ctx, "herp", "other")
    @test idx == 62
    @test has_val == false

    # Insert another
    AwsHTTP.hpack_insert_header!(ctx, "fizz", "buzz")
    idx, has_val = AwsHTTP.hpack_find_index(ctx, "fizz", "buzz")
    @test idx == 62
    @test has_val == true

    # Old entry shifted
    idx, has_val = AwsHTTP.hpack_find_index(ctx, "herp", "derp")
    @test idx == 63
    @test has_val == true
end

@testset "HPACK dynamic table - get by index" begin
    ctx = AwsHTTP.HpackContext()

    AwsHTTP.hpack_insert_header!(ctx, ":status", "302")
    AwsHTTP.hpack_insert_header!(ctx, "a", "b")
    AwsHTTP.hpack_insert_header!(ctx, "fizz", "buzz")

    h = AwsHTTP.hpack_get_header(ctx, 62)
    @test h == ("fizz", "buzz")

    h = AwsHTTP.hpack_get_header(ctx, 63)
    @test h == ("a", "b")

    h = AwsHTTP.hpack_get_header(ctx, 64)
    @test h == (":status", "302")

    @test AwsHTTP.hpack_get_header(ctx, 65) === nothing
end

@testset "HPACK dynamic table - eviction on resize" begin
    ctx = AwsHTTP.HpackContext()

    AwsHTTP.hpack_insert_header!(ctx, "herp", "derp")
    AwsHTTP.hpack_insert_header!(ctx, "fizz", "buzz")

    # Resize to only fit one entry
    fizz_size = AwsHTTP.hpack_get_header_size("fizz", "buzz")
    AwsHTTP.hpack_resize_dynamic_table!(ctx, fizz_size)

    # fizz survives, herp evicted
    idx, has_val = AwsHTTP.hpack_find_index(ctx, "fizz", "buzz")
    @test idx == 62
    @test has_val == true

    idx, _ = AwsHTTP.hpack_find_index(ctx, "herp", "derp")
    @test idx == 0
end

@testset "HPACK dynamic table - oversized header" begin
    ctx = AwsHTTP.HpackContext()

    # Set small table
    AwsHTTP.hpack_resize_dynamic_table!(ctx, 32)

    AwsHTTP.hpack_insert_header!(ctx, "a", "b")  # 1 + 1 + 32 = 34 > 32
    # Entry too large: table cleared, entry not inserted
    @test AwsHTTP.hpack_get_dynamic_table_num_elements(ctx) == 0
end

@testset "HPACK dynamic table - empty value" begin
    ctx = AwsHTTP.HpackContext()

    AwsHTTP.hpack_insert_header!(ctx, ":status", "302")
    AwsHTTP.hpack_insert_header!(ctx, "c", "")
    AwsHTTP.hpack_insert_header!(ctx, "a", "b")

    h = AwsHTTP.hpack_get_header(ctx, 62)
    @test h == ("a", "b")
    h = AwsHTTP.hpack_get_header(ctx, 63)
    @test h == ("c", "")
    h = AwsHTTP.hpack_get_header(ctx, 64)
    @test h == (":status", "302")
end

# ── HPACK Decoder ──

@testset "HPACK decoder - indexed from static table" begin
    dec = AwsHTTP.hpack_decoder_init()
    # 0x82 = 10000010 → indexed, index 2 → :method GET
    data = UInt8[0x82]
    pos = Ref(1)
    status, result = AwsHTTP.hpack_decode!(dec, data, pos)
    @test status == Reseau.OP_SUCCESS
    @test result.type == AwsHTTP.HpackDecodeType.HEADER_FIELD
    @test result.header_name == ":method"
    @test result.header_value == "GET"
end

@testset "HPACK decoder - literal with indexing" begin
    dec = AwsHTTP.hpack_decoder_init()
    # 0x40 = literal with incremental indexing, name index 0 (new name)
    # followed by name string and value string
    data = UInt8[
        0x40,              # literal with indexing, name_index=0
        0x01, UInt8('a'),  # name: "a" (length 1, no Huffman)
        0x01, UInt8('b'),  # value: "b" (length 1, no Huffman)
    ]
    pos = Ref(1)
    status, result = AwsHTTP.hpack_decode!(dec, data, pos)
    @test status == Reseau.OP_SUCCESS
    @test result.type == AwsHTTP.HpackDecodeType.HEADER_FIELD
    @test result.header_name == "a"
    @test result.header_value == "b"

    # Should be in dynamic table now
    h = AwsHTTP.hpack_get_header(dec.context, 62)
    @test h == ("a", "b")
end

@testset "HPACK decoder - literal with indexed name" begin
    dec = AwsHTTP.hpack_decoder_init()
    # 0x48 = 01001000 = literal with indexing, name index 8 → :status
    # value: "302" (length 3)
    data = UInt8[
        0x48,                                    # literal with indexing, name_index=8
        0x03, UInt8('3'), UInt8('0'), UInt8('2'), # value: "302"
    ]
    pos = Ref(1)
    status, result = AwsHTTP.hpack_decode!(dec, data, pos)
    @test status == Reseau.OP_SUCCESS
    @test result.type == AwsHTTP.HpackDecodeType.HEADER_FIELD
    @test result.header_name == ":status"
    @test result.header_value == "302"

    h = AwsHTTP.hpack_get_header(dec.context, 62)
    @test h == (":status", "302")
end

@testset "HPACK decoder - indexed from dynamic table" begin
    dec = AwsHTTP.hpack_decoder_init()

    # First: literal with indexing, :status 302
    data = UInt8[
        0x48, 0x03, UInt8('3'), UInt8('0'), UInt8('2'),  # :status 302
        0x40, 0x01, UInt8('a'), 0x01, UInt8('b'),        # a: b
        0xbf,  # indexed: index 63 → :status 302 (second in dynamic table)
    ]
    pos = Ref(1)

    # Decode first header
    status, r1 = AwsHTTP.hpack_decode!(dec, data, pos)
    @test r1.header_name == ":status"
    @test r1.header_value == "302"

    # Decode second header
    status, r2 = AwsHTTP.hpack_decode!(dec, data, pos)
    @test r2.header_name == "a"
    @test r2.header_value == "b"

    # Decode third (indexed from dynamic table)
    status, r3 = AwsHTTP.hpack_decode!(dec, data, pos)
    @test status == Reseau.OP_SUCCESS
    @test r3.type == AwsHTTP.HpackDecodeType.HEADER_FIELD
    @test r3.header_name == ":status"
    @test r3.header_value == "302"
end

@testset "HPACK decoder - dynamic table size update" begin
    dec = AwsHTTP.hpack_decoder_init()
    # 0x20 = 001|00000 → table size update, size 0
    data = UInt8[0x20]
    pos = Ref(1)
    status, result = AwsHTTP.hpack_decode!(dec, data, pos)
    @test status == Reseau.OP_SUCCESS
    @test result.type == AwsHTTP.HpackDecodeType.DYNAMIC_TABLE_RESIZE
    @test result.dynamic_table_resize == 0
    @test AwsHTTP.hpack_get_dynamic_table_max_size(dec.context) == 0
end

@testset "HPACK decoder - name too large" begin
    dec = AwsHTTP.hpack_decoder_init()
    AwsHTTP.hpack_decoder_set_max_string_length!(dec, 3)
    # literal without indexing, name length 4 (exceeds max of 3)
    data = UInt8[0x00, 0x04, UInt8('n'), UInt8('a'), UInt8('m'), UInt8('e'), 0x01, UInt8('v')]
    pos = Ref(1)
    status, result = AwsHTTP.hpack_decode!(dec, data, pos)
    @test status != Reseau.OP_SUCCESS
end

@testset "HPACK decoder - value too large" begin
    dec = AwsHTTP.hpack_decoder_init()
    AwsHTTP.hpack_decoder_set_max_string_length!(dec, 3)
    # literal without indexing, name "n" (len 1), value "valu" (len 4, exceeds max)
    data = UInt8[0x00, 0x01, UInt8('n'), 0x04, UInt8('v'), UInt8('a'), UInt8('l'), UInt8('u')]
    pos = Ref(1)
    status, result = AwsHTTP.hpack_decode!(dec, data, pos)
    # First call may succeed (decodes name), but value decode should fail
    if status == Reseau.OP_SUCCESS && result.type == AwsHTTP.HpackDecodeType.ONGOING
        status, result = AwsHTTP.hpack_decode!(dec, data, pos)
    end
    @test status != Reseau.OP_SUCCESS
end

@testset "HPACK decoder - one byte at a time" begin
    dec = AwsHTTP.hpack_decoder_init()
    # Literal with indexing: name_index=8 (:status), value="302"
    full_data = UInt8[0x48, 0x03, UInt8('3'), UInt8('0'), UInt8('2')]

    result = AwsHTTP.HpackDecodeResult()
    global_pos = 1
    while global_pos <= length(full_data)
        chunk = UInt8[full_data[global_pos]]
        pos = Ref(1)
        status, result = AwsHTTP.hpack_decode!(dec, chunk, pos)
        @test status == Reseau.OP_SUCCESS
        global_pos += pos[] - 1
        result.type != AwsHTTP.HpackDecodeType.ONGOING && break
    end
    @test result.type == AwsHTTP.HpackDecodeType.HEADER_FIELD
    @test result.header_name == ":status"
    @test result.header_value == "302"
end

# ── HPACK Encoder ──

@testset "HPACK encoder - encode :method GET (indexed)" begin
    enc = AwsHTTP.hpack_encoder_init()
    AwsHTTP.hpack_encoder_set_huffman_mode!(enc, AwsHTTP.HpackHuffmanMode.NEVER)

    hdrs = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add_header(hdrs, AwsHTTP.HttpHeader(":method", "GET"))

    status, encoded = AwsHTTP.hpack_encode_header_block(enc, hdrs)
    @test status == Reseau.OP_SUCCESS
    @test encoded == UInt8[0x82]  # indexed, index 2
end

@testset "HPACK encoder - encode literal with indexing" begin
    enc = AwsHTTP.hpack_encoder_init()
    AwsHTTP.hpack_encoder_set_huffman_mode!(enc, AwsHTTP.HpackHuffmanMode.NEVER)

    hdrs = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add_header(hdrs, AwsHTTP.HttpHeader("custom-key", "custom-value",
                                                              AwsHTTP.HttpHeaderCompression.USE_CACHE))

    status, encoded = AwsHTTP.hpack_encode_header_block(enc, hdrs)
    @test status == Reseau.OP_SUCCESS

    # Decode it back
    dec = AwsHTTP.hpack_decoder_init()
    pos = Ref(1)
    status, result = AwsHTTP.hpack_decode!(dec, encoded, pos)
    @test status == Reseau.OP_SUCCESS
    @test result.header_name == "custom-key"
    @test result.header_value == "custom-value"
end

@testset "HPACK encoder - size update from settings" begin
    enc = AwsHTTP.hpack_encoder_init()
    AwsHTTP.hpack_encoder_set_huffman_mode!(enc, AwsHTTP.HpackHuffmanMode.NEVER)

    AwsHTTP.hpack_encoder_update_max_table_size!(enc, UInt32(0))
    AwsHTTP.hpack_encoder_update_max_table_size!(enc, UInt32(1337))

    hdrs = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add_header(hdrs, AwsHTTP.HttpHeader(":method", "GET"))

    status, encoded = AwsHTTP.hpack_encode_header_block(enc, hdrs)
    @test status == Reseau.OP_SUCCESS

    # Should contain: size_update(0), size_update(1337), indexed(:method GET)
    @test encoded[1] == 0x20  # size update 0
    @test encoded[2:4] == UInt8[0x3f, 0x9a, 0x0a]  # size update 1337 (5-bit prefix)
    @test encoded[5] == 0x82  # indexed :method GET
end

@testset "HPACK encoder/decoder roundtrip" begin
    enc = AwsHTTP.hpack_encoder_init()
    AwsHTTP.hpack_encoder_set_huffman_mode!(enc, AwsHTTP.HpackHuffmanMode.NEVER)

    hdrs = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add_header(hdrs, AwsHTTP.HttpHeader(":method", "GET"))
    AwsHTTP.http_headers_add_header(hdrs, AwsHTTP.HttpHeader(":path", "/"))
    AwsHTTP.http_headers_add_header(hdrs, AwsHTTP.HttpHeader(":scheme", "https"))
    AwsHTTP.http_headers_add_header(hdrs, AwsHTTP.HttpHeader("custom-key", "custom-value"))

    status, encoded = AwsHTTP.hpack_encode_header_block(enc, hdrs)
    @test status == Reseau.OP_SUCCESS

    # Decode all headers
    dec = AwsHTTP.hpack_decoder_init()
    pos = Ref(1)
    decoded_headers = Tuple{String,String}[]
    while pos[] <= length(encoded)
        status, result = AwsHTTP.hpack_decode!(dec, encoded, pos)
        @test status == Reseau.OP_SUCCESS
        if result.type == AwsHTTP.HpackDecodeType.HEADER_FIELD
            push!(decoded_headers, (result.header_name, result.header_value))
        end
    end
    @test length(decoded_headers) == 4
    @test decoded_headers[1] == (":method", "GET")
    @test decoded_headers[2] == (":path", "/")
    @test decoded_headers[3] == (":scheme", "https")
    @test decoded_headers[4] == ("custom-key", "custom-value")
end

@testset "HPACK encoder/decoder roundtrip with Huffman" begin
    enc = AwsHTTP.hpack_encoder_init()
    AwsHTTP.hpack_encoder_set_huffman_mode!(enc, AwsHTTP.HpackHuffmanMode.ALWAYS)

    hdrs = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add_header(hdrs, AwsHTTP.HttpHeader(":method", "GET"))
    AwsHTTP.http_headers_add_header(hdrs, AwsHTTP.HttpHeader(":path", "/index.html"))
    AwsHTTP.http_headers_add_header(hdrs, AwsHTTP.HttpHeader("host", "www.example.com",
                                                              AwsHTTP.HttpHeaderCompression.USE_CACHE))

    status, encoded = AwsHTTP.hpack_encode_header_block(enc, hdrs)
    @test status == Reseau.OP_SUCCESS

    dec = AwsHTTP.hpack_decoder_init()
    pos = Ref(1)
    decoded = Tuple{String,String}[]
    while pos[] <= length(encoded)
        status, result = AwsHTTP.hpack_decode!(dec, encoded, pos)
        @test status == Reseau.OP_SUCCESS
        if result.type == AwsHTTP.HpackDecodeType.HEADER_FIELD
            push!(decoded, (result.header_name, result.header_value))
        end
    end
    @test length(decoded) == 3
    @test decoded[1] == (":method", "GET")
    @test decoded[2] == (":path", "/index.html")
    @test decoded[3] == ("host", "www.example.com")
end

# ─── Phase 7: HTTP/2 Frames ───

@testset "H2 frame type enum and string conversion" begin
    @test AwsHTTP.H2FrameType.DATA == AwsHTTP.H2FrameType.T(0x00)
    @test AwsHTTP.H2FrameType.HEADERS == AwsHTTP.H2FrameType.T(0x01)
    @test AwsHTTP.H2FrameType.PRIORITY == AwsHTTP.H2FrameType.T(0x02)
    @test AwsHTTP.H2FrameType.RST_STREAM == AwsHTTP.H2FrameType.T(0x03)
    @test AwsHTTP.H2FrameType.SETTINGS == AwsHTTP.H2FrameType.T(0x04)
    @test AwsHTTP.H2FrameType.PUSH_PROMISE == AwsHTTP.H2FrameType.T(0x05)
    @test AwsHTTP.H2FrameType.PING == AwsHTTP.H2FrameType.T(0x06)
    @test AwsHTTP.H2FrameType.GOAWAY == AwsHTTP.H2FrameType.T(0x07)
    @test AwsHTTP.H2FrameType.WINDOW_UPDATE == AwsHTTP.H2FrameType.T(0x08)
    @test AwsHTTP.H2FrameType.CONTINUATION == AwsHTTP.H2FrameType.T(0x09)
    @test AwsHTTP.h2_frame_type_to_str(AwsHTTP.H2FrameType.DATA) == "DATA"
    @test AwsHTTP.h2_frame_type_to_str(AwsHTTP.H2FrameType.GOAWAY) == "GOAWAY"
    @test AwsHTTP.h2_frame_type_to_str(AwsHTTP.H2FrameType.UNKNOWN) == "UNKNOWN"
end

@testset "H2 frame flags constants" begin
    @test AwsHTTP.H2_FRAME_F_ACK == 0x01
    @test AwsHTTP.H2_FRAME_F_END_STREAM == 0x01
    @test AwsHTTP.H2_FRAME_F_END_HEADERS == 0x04
    @test AwsHTTP.H2_FRAME_F_PADDED == 0x08
    @test AwsHTTP.H2_FRAME_F_PRIORITY == 0x20
end

@testset "H2 frame constants" begin
    @test AwsHTTP.H2_PAYLOAD_MAX == 0x00FFFFFF
    @test AwsHTTP.H2_WINDOW_UPDATE_MAX == 0x7FFFFFFF
    @test AwsHTTP.H2_STREAM_ID_MAX == 0x7FFFFFFF
    @test AwsHTTP.H2_FRAME_PREFIX_SIZE == 9
    @test AwsHTTP.H2_INIT_WINDOW_SIZE == 65535
    @test AwsHTTP.H2_PING_DATA_SIZE == 8
    @test length(AwsHTTP.H2_CONNECTION_PREFACE_CLIENT) == 24
end

@testset "H2Err construction and checks" begin
    s = AwsHTTP.H2ERR_SUCCESS
    @test AwsHTTP.h2err_success(s)
    @test !AwsHTTP.h2err_failed(s)

    e1 = AwsHTTP.h2err_from_h2_code(AwsHTTP.Http2ErrorCode.PROTOCOL_ERROR)
    @test AwsHTTP.h2err_failed(e1)
    @test e1.h2_code == AwsHTTP.Http2ErrorCode.PROTOCOL_ERROR

    e2 = AwsHTTP.h2err_from_aws_code(AwsHTTP.ERROR_HTTP_PROTOCOL_ERROR)
    @test AwsHTTP.h2err_failed(e2)
    @test e2.h2_code == AwsHTTP.Http2ErrorCode.INTERNAL_ERROR
end

@testset "H2 validate stream ID" begin
    @test AwsHTTP.h2_validate_stream_id(UInt32(1)) == Reseau.OP_SUCCESS
    @test AwsHTTP.h2_validate_stream_id(UInt32(0x7FFFFFFF)) == Reseau.OP_SUCCESS
    @test AwsHTTP.h2_validate_stream_id(UInt32(0)) == Reseau.OP_ERR
    @test AwsHTTP.h2_validate_stream_id(UInt32(0x80000000)) == Reseau.OP_ERR
end

@testset "Http2SettingsId enum" begin
    @test UInt16(AwsHTTP.Http2SettingsId.HEADER_TABLE_SIZE) == 0x01
    @test UInt16(AwsHTTP.Http2SettingsId.ENABLE_PUSH) == 0x02
    @test UInt16(AwsHTTP.Http2SettingsId.MAX_CONCURRENT_STREAMS) == 0x03
    @test UInt16(AwsHTTP.Http2SettingsId.INITIAL_WINDOW_SIZE) == 0x04
    @test UInt16(AwsHTTP.Http2SettingsId.MAX_FRAME_SIZE) == 0x05
    @test UInt16(AwsHTTP.Http2SettingsId.MAX_HEADER_LIST_SIZE) == 0x06
end

@testset "H2 settings bounds and initial values" begin
    # Initial values match RFC 7540 6.5.2
    @test AwsHTTP.H2_SETTINGS_INITIAL[AwsHTTP.Http2SettingsId.HEADER_TABLE_SIZE] == 4096
    @test AwsHTTP.H2_SETTINGS_INITIAL[AwsHTTP.Http2SettingsId.ENABLE_PUSH] == 1
    @test AwsHTTP.H2_SETTINGS_INITIAL[AwsHTTP.Http2SettingsId.INITIAL_WINDOW_SIZE] == 65535
    @test AwsHTTP.H2_SETTINGS_INITIAL[AwsHTTP.Http2SettingsId.MAX_FRAME_SIZE] == 16384

    # Bounds: ENABLE_PUSH is 0..1
    bounds = AwsHTTP.H2_SETTINGS_BOUNDS[AwsHTTP.Http2SettingsId.ENABLE_PUSH]
    @test bounds == (UInt32(0), UInt32(1))

    # Bounds: MAX_FRAME_SIZE is 16384..H2_PAYLOAD_MAX
    bounds = AwsHTTP.H2_SETTINGS_BOUNDS[AwsHTTP.Http2SettingsId.MAX_FRAME_SIZE]
    @test bounds[1] == UInt32(16384)
    @test bounds[2] == UInt32(AwsHTTP.H2_PAYLOAD_MAX)
end

@testset "H2 frame prefix encode/decode roundtrip" begin
    prefix = AwsHTTP._h2_encode_frame_prefix(UInt32(256), UInt8(AwsHTTP.H2FrameType.HEADERS),
        AwsHTTP.H2_FRAME_F_END_STREAM | AwsHTTP.H2_FRAME_F_END_HEADERS, UInt32(7))
    @test length(prefix) == 9
    decoded, next_pos = AwsHTTP._h2_decode_frame_prefix(prefix, 1)
    @test next_pos == 10
    @test decoded.payload_len == 256
    @test decoded.frame_type == AwsHTTP.H2FrameType.HEADERS
    @test decoded.flags == (AwsHTTP.H2_FRAME_F_END_STREAM | AwsHTTP.H2_FRAME_F_END_HEADERS)
    @test decoded.stream_id == 7
end

@testset "H2 priority encoding/decoding" begin
    p = AwsHTTP.Http2PrioritySettings(UInt32(0x01234567), true, UInt16(9))
    encoded = AwsHTTP._h2_encode_priority(p)
    @test length(encoded) == 5
    # Top bit should be set (exclusive=true)
    @test (encoded[1] & 0x80) != 0
    decoded, next_pos = AwsHTTP._h2_decode_priority(encoded, 1)
    @test next_pos == 6
    @test decoded.stream_dependency == 0x01234567
    @test decoded.stream_dependency_exclusive == true
    @test decoded.weight == 9
end

# ─── Encoder tests ───

@testset "H2 encoder - PRIORITY frame" begin
    priority = AwsHTTP.Http2PrioritySettings(UInt32(0x01234567), true, UInt16(9))
    status, encoded = AwsHTTP.h2_encode_priority_frame(UInt32(0x76543210), priority)
    @test status == Reseau.OP_SUCCESS
    expected = UInt8[
        0x00, 0x00, 0x05,           # Length = 5
        0x02,                        # Type = PRIORITY
        0x00,                        # Flags = none
        0x76, 0x54, 0x32, 0x10,     # Stream ID
        0x81, 0x23, 0x45, 0x67,     # Exclusive + Dependency
        0x09,                        # Weight
    ]
    @test encoded == expected
end

@testset "H2 encoder - RST_STREAM frame" begin
    status, encoded = AwsHTTP.h2_encode_rst_stream(UInt32(0x76543210), UInt32(0xFEEDBEEF))
    @test status == Reseau.OP_SUCCESS
    expected = UInt8[
        0x00, 0x00, 0x04,           # Length = 4
        0x03,                        # Type = RST_STREAM
        0x00,                        # Flags
        0x76, 0x54, 0x32, 0x10,     # Stream ID
        0xFE, 0xED, 0xBE, 0xEF,     # Error Code
    ]
    @test encoded == expected
end

@testset "H2 encoder - SETTINGS frame" begin
    settings = [
        AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.ENABLE_PUSH, UInt32(1)),
    ]
    status, encoded = AwsHTTP.h2_encode_settings(settings)
    @test status == Reseau.OP_SUCCESS
    expected = UInt8[
        0x00, 0x00, 0x06,           # Length = 6
        0x04,                        # Type = SETTINGS
        0x00,                        # Flags
        0x00, 0x00, 0x00, 0x00,     # Stream ID = 0
        0x00, 0x02,                  # Setting ID = ENABLE_PUSH
        0x00, 0x00, 0x00, 0x01,     # Value = 1
    ]
    @test encoded == expected
end

@testset "H2 encoder - SETTINGS ACK" begin
    status, encoded = AwsHTTP.h2_encode_settings(AwsHTTP.Http2Setting[]; ack=true)
    @test status == Reseau.OP_SUCCESS
    expected = UInt8[
        0x00, 0x00, 0x00,           # Length = 0
        0x04,                        # Type = SETTINGS
        0x01,                        # Flags = ACK
        0x00, 0x00, 0x00, 0x00,     # Stream ID = 0
    ]
    @test encoded == expected
end

@testset "H2 encoder - PING frame with ACK" begin
    opaque = UInt8[0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
    status, encoded = AwsHTTP.h2_encode_ping(opaque; ack=true)
    @test status == Reseau.OP_SUCCESS
    expected = UInt8[
        0x00, 0x00, 0x08,           # Length = 8
        0x06,                        # Type = PING
        0x01,                        # Flags = ACK
        0x00, 0x00, 0x00, 0x00,     # Stream ID = 0
        0x00, 0x01, 0x02, 0x03,     # Opaque data
        0x04, 0x05, 0x06, 0x07,
    ]
    @test encoded == expected
end

@testset "H2 encoder - GOAWAY frame" begin
    debug = Vector{UInt8}(codeunits("goodbye"))
    status, encoded = AwsHTTP.h2_encode_goaway(UInt32(0x77665544), UInt32(0xFFEEDDCC); debug_data=debug)
    @test status == Reseau.OP_SUCCESS
    expected = UInt8[
        0x00, 0x00, 0x0F,           # Length = 15
        0x07,                        # Type = GOAWAY
        0x00,                        # Flags
        0x00, 0x00, 0x00, 0x00,     # Stream ID = 0
        0x77, 0x66, 0x55, 0x44,     # Last-Stream-ID
        0xFF, 0xEE, 0xDD, 0xCC,     # Error Code
        UInt8('g'), UInt8('o'), UInt8('o'), UInt8('d'), UInt8('b'), UInt8('y'), UInt8('e'),
    ]
    @test encoded == expected
end

@testset "H2 encoder - WINDOW_UPDATE frame" begin
    status, encoded = AwsHTTP.h2_encode_window_update(UInt32(0x76543210), UInt32(0x7FFFFFFF))
    @test status == Reseau.OP_SUCCESS
    expected = UInt8[
        0x00, 0x00, 0x04,           # Length = 4
        0x08,                        # Type = WINDOW_UPDATE
        0x00,                        # Flags
        0x76, 0x54, 0x32, 0x10,     # Stream ID
        0x7F, 0xFF, 0xFF, 0xFF,     # Window increment (max)
    ]
    @test encoded == expected
end

@testset "H2 encoder - DATA frame" begin
    body = UInt8[0x48, 0x65, 0x6C, 0x6C, 0x6F]  # "Hello"
    status, encoded = AwsHTTP.h2_encode_data(UInt32(1), body; end_stream=true)
    @test status == Reseau.OP_SUCCESS
    @test length(encoded) == 9 + 5
    # Check prefix
    @test encoded[1:3] == UInt8[0x00, 0x00, 0x05]  # Length = 5
    @test encoded[4] == 0x00  # Type = DATA
    @test encoded[5] == 0x01  # Flags = END_STREAM
    @test encoded[10:14] == body
end

@testset "H2 encoder - DATA frame with padding" begin
    body = UInt8[0x48, 0x65, 0x6C, 0x6C, 0x6F]  # "Hello"
    status, encoded = AwsHTTP.h2_encode_data(UInt32(0x76543210), body;
        end_stream=true, pad_length=0x02)
    @test status == Reseau.OP_SUCCESS
    # Payload = 1(pad_len) + 5(body) + 2(padding) = 8
    expected = UInt8[
        0x00, 0x00, 0x08,           # Length = 8
        0x00,                        # Type = DATA
        0x09,                        # Flags = END_STREAM | PADDED
        0x76, 0x54, 0x32, 0x10,     # Stream ID
        0x02,                        # Pad length
        0x48, 0x65, 0x6C, 0x6C, 0x6F,  # Body
        0x00, 0x00,                  # Padding
    ]
    @test encoded == expected
end

@testset "H2 encoder - HEADERS frame (simple)" begin
    enc = AwsHTTP.h2_frame_encoder_new()
    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, ":method", "GET")
    AwsHTTP.http_headers_add(headers, ":path", "/")

    status, encoded = AwsHTTP.h2_encode_headers(enc, UInt32(1), headers; end_stream=true)
    @test status == Reseau.OP_SUCCESS
    @test length(encoded) > 9  # prefix + at least some header bytes
    # Check frame type
    @test encoded[4] == UInt8(AwsHTTP.H2FrameType.HEADERS)
    # Should have END_STREAM and END_HEADERS flags
    @test (encoded[5] & AwsHTTP.H2_FRAME_F_END_STREAM) != 0
    @test (encoded[5] & AwsHTTP.H2_FRAME_F_END_HEADERS) != 0
end

@testset "H2 encoder - RST_STREAM fails with stream_id=0" begin
    status, _ = AwsHTTP.h2_encode_rst_stream(UInt32(0), UInt32(1))
    @test status == Reseau.OP_ERR
end

@testset "H2 encoder - WINDOW_UPDATE fails with oversized increment" begin
    status, _ = AwsHTTP.h2_encode_window_update(UInt32(1), UInt32(0x80000000))
    @test status == Reseau.OP_ERR
end

# ─── Decoder tests ───

@testset "H2 decoder - construction" begin
    dec = AwsHTTP.h2_decoder_new(is_server=true)
    @test dec.is_server == true
    @test dec.max_frame_size == 16384
    @test dec.connection_preface_complete == false
end

@testset "H2 decoder - SETTINGS frame (client-side, no preface needed)" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    settings = [AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.ENABLE_PUSH, UInt32(0))]
    _, frame_data = AwsHTTP.h2_encode_settings(settings)

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.SETTINGS
    @test !frame.ack
    @test length(frame.settings) == 1
    @test frame.settings[1].id == AwsHTTP.Http2SettingsId.ENABLE_PUSH
    @test frame.settings[1].value == 0
    @test pos == length(frame_data) + 1
end

@testset "H2 decoder - SETTINGS ACK" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    _, frame_data = AwsHTTP.h2_encode_settings(AwsHTTP.Http2Setting[]; ack=true)

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.SETTINGS
    @test frame.ack
end

@testset "H2 decoder - PING roundtrip" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    opaque = UInt8[0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
    _, frame_data = AwsHTTP.h2_encode_ping(opaque; ack=true)

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.PING
    @test frame.ack
    @test frame.opaque_data == opaque
end

@testset "H2 decoder - RST_STREAM roundtrip" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    _, frame_data = AwsHTTP.h2_encode_rst_stream(UInt32(1), UInt32(0xFEEDBEEF))

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.RST_STREAM
    @test frame.stream_id == 1
    @test frame.error_code == 0xFEEDBEEF
end

@testset "H2 decoder - GOAWAY roundtrip" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    debug = Vector{UInt8}(codeunits("test"))
    _, frame_data = AwsHTTP.h2_encode_goaway(UInt32(3), UInt32(0x02); debug_data=debug)

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.GOAWAY
    @test frame.last_stream_id == 3
    @test frame.goaway_error_code == 0x02
    @test frame.debug_data == debug
end

@testset "H2 decoder - WINDOW_UPDATE roundtrip" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    _, frame_data = AwsHTTP.h2_encode_window_update(UInt32(5), UInt32(32768))

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.WINDOW_UPDATE
    @test frame.stream_id == 5
    @test frame.window_increment == 32768
end

@testset "H2 decoder - PRIORITY roundtrip" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    priority = AwsHTTP.Http2PrioritySettings(UInt32(3), true, UInt16(255))
    _, frame_data = AwsHTTP.h2_encode_priority_frame(UInt32(7), priority)

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.PRIORITY
    @test frame.stream_id == 7
    @test frame.priority !== nothing
    @test frame.priority.stream_dependency == 3
    @test frame.priority.stream_dependency_exclusive == true
    @test frame.priority.weight == 255
end

@testset "H2 decoder - DATA frame roundtrip" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    body = Vector{UInt8}(codeunits("Hello, HTTP/2!"))
    _, frame_data = AwsHTTP.h2_encode_data(UInt32(1), body; end_stream=true)

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.DATA
    @test frame.stream_id == 1
    @test frame.end_stream == true
    @test frame.data == body
end

@testset "H2 decoder - DATA frame with padding" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    body = UInt8[0x48, 0x65, 0x6C, 0x6C, 0x6F]
    _, frame_data = AwsHTTP.h2_encode_data(UInt32(1), body; pad_length=0x03)

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.DATA
    @test frame.data == body
end

@testset "H2 decoder - HEADERS roundtrip" begin
    enc = AwsHTTP.h2_frame_encoder_new()
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(headers, ":method", "GET")
    AwsHTTP.http_headers_add(headers, ":path", "/")
    AwsHTTP.http_headers_add(headers, ":scheme", "https")
    AwsHTTP.http_headers_add(headers, ":authority", "example.com")

    status, frame_data = AwsHTTP.h2_encode_headers(enc, UInt32(1), headers; end_stream=true)
    @test status == Reseau.OP_SUCCESS

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.HEADERS
    @test frame.stream_id == 1
    @test frame.end_stream == true
    @test length(frame.headers) == 4
    @test frame.headers[1].name == ":method"
    @test frame.headers[1].value == "GET"
    @test frame.headers[2].name == ":path"
    @test frame.headers[2].value == "/"
    @test frame.headers[3].name == ":scheme"
    @test frame.headers[3].value == "https"
    @test frame.headers[4].name == ":authority"
    @test frame.headers[4].value == "example.com"
end

@testset "H2 decoder - stream ID validation" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    # SETTINGS with non-zero stream ID should fail
    bad_settings = AwsHTTP._h2_encode_frame_prefix(UInt32(0), UInt8(AwsHTTP.H2FrameType.SETTINGS), 0x00, UInt32(1))
    err, _, _ = AwsHTTP.h2_decode_frame(dec, bad_settings, 1)
    @test AwsHTTP.h2err_failed(err)
    @test err.h2_code == AwsHTTP.Http2ErrorCode.PROTOCOL_ERROR
end

@testset "H2 decoder - SETTINGS invalid ACK with payload" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    # ACK with non-zero payload length
    bad_ack = UInt8[
        0x00, 0x00, 0x06,  # Length = 6
        0x04,               # Type = SETTINGS
        0x01,               # Flags = ACK
        0x00, 0x00, 0x00, 0x00,  # Stream ID = 0
        0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  # bogus settings data
    ]
    err, _, _ = AwsHTTP.h2_decode_frame(dec, bad_ack, 1)
    @test AwsHTTP.h2err_failed(err)
    @test err.h2_code == AwsHTTP.Http2ErrorCode.FRAME_SIZE_ERROR
end

@testset "H2 decoder - SETTINGS invalid payload length" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    # Payload not multiple of 6
    bad = UInt8[
        0x00, 0x00, 0x05,  # Length = 5 (not % 6)
        0x04,               # Type = SETTINGS
        0x00,               # Flags
        0x00, 0x00, 0x00, 0x00,  # Stream ID = 0
        0x00, 0x01, 0x00, 0x00, 0x01,  # 5 bytes
    ]
    err, _, _ = AwsHTTP.h2_decode_frame(dec, bad, 1)
    @test AwsHTTP.h2err_failed(err)
    @test err.h2_code == AwsHTTP.Http2ErrorCode.FRAME_SIZE_ERROR
end

@testset "H2 decoder - SETTINGS invalid ENABLE_PUSH value" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    bad = UInt8[
        0x00, 0x00, 0x06,  # Length = 6
        0x04,               # Type = SETTINGS
        0x00,               # Flags
        0x00, 0x00, 0x00, 0x00,  # Stream ID = 0
        0x00, 0x02,              # ENABLE_PUSH
        0x00, 0x00, 0x00, 0x02,  # Value = 2 (invalid, must be 0 or 1)
    ]
    err, _, _ = AwsHTTP.h2_decode_frame(dec, bad, 1)
    @test AwsHTTP.h2err_failed(err)
    @test err.h2_code == AwsHTTP.Http2ErrorCode.PROTOCOL_ERROR
end

@testset "H2 decoder - SETTINGS INITIAL_WINDOW_SIZE out of bounds" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    bad = UInt8[
        0x00, 0x00, 0x06,  # Length = 6
        0x04,               # Type = SETTINGS
        0x00,               # Flags
        0x00, 0x00, 0x00, 0x00,  # Stream ID = 0
        0x00, 0x04,              # INITIAL_WINDOW_SIZE
        0x80, 0x00, 0x00, 0x00,  # Value = 2^31 (exceeds max)
    ]
    err, _, _ = AwsHTTP.h2_decode_frame(dec, bad, 1)
    @test AwsHTTP.h2err_failed(err)
    @test err.h2_code == AwsHTTP.Http2ErrorCode.FLOW_CONTROL_ERROR
end

@testset "H2 decoder - connection preface (server)" begin
    dec = AwsHTTP.h2_decoder_new(is_server=true)

    # Build: preface + SETTINGS frame
    settings = [AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.MAX_CONCURRENT_STREAMS, UInt32(100))]
    _, settings_frame = AwsHTTP.h2_encode_settings(settings)
    wire = vcat(Vector{UInt8}(AwsHTTP.H2_CONNECTION_PREFACE_CLIENT), settings_frame)

    err, frame, pos = AwsHTTP.h2_decode_frame(dec, wire, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.SETTINGS
    @test dec.connection_preface_complete == true
    @test length(frame.settings) == 1
    @test frame.settings[1].value == 100
end

@testset "H2 decoder - bad connection preface" begin
    dec = AwsHTTP.h2_decoder_new(is_server=true)

    # Bad preface
    bad = b"BAD PREFACE DATA THAT IS LONG ENOUGH TO PARSE"
    err, _, _ = AwsHTTP.h2_decode_frame(dec, bad, 1)
    @test AwsHTTP.h2err_failed(err)
end

@testset "H2 decoder - multiple frames sequential" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    # Concatenate several frames
    _, f1 = AwsHTTP.h2_encode_window_update(UInt32(0), UInt32(1000))
    _, f2 = AwsHTTP.h2_encode_ping(UInt8[1,2,3,4,5,6,7,8])
    _, f3 = AwsHTTP.h2_encode_window_update(UInt32(1), UInt32(500))
    wire = vcat(f1, f2, f3)

    err1, frame1, pos1 = AwsHTTP.h2_decode_frame(dec, wire, 1)
    @test AwsHTTP.h2err_success(err1)
    @test frame1.frame_type == AwsHTTP.H2FrameType.WINDOW_UPDATE
    @test frame1.window_increment == 1000

    err2, frame2, pos2 = AwsHTTP.h2_decode_frame(dec, wire, pos1)
    @test AwsHTTP.h2err_success(err2)
    @test frame2.frame_type == AwsHTTP.H2FrameType.PING

    err3, frame3, pos3 = AwsHTTP.h2_decode_frame(dec, wire, pos2)
    @test AwsHTTP.h2err_success(err3)
    @test frame3.frame_type == AwsHTTP.H2FrameType.WINDOW_UPDATE
    @test frame3.window_increment == 500
    @test pos3 == length(wire) + 1
end

@testset "H2 decoder - incomplete data returns UNKNOWN (need more)" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    # Only 5 bytes, need at least 9 for prefix
    partial = UInt8[0x00, 0x00, 0x04, 0x08, 0x00]
    err, frame, pos = AwsHTTP.h2_decode_frame(dec, partial, 1)
    @test AwsHTTP.h2err_success(err)
    @test frame.frame_type == AwsHTTP.H2FrameType.UNKNOWN
    @test pos == 1  # pos unchanged
end

@testset "H2 decoder - CONTINUATION without HEADERS fails" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    # CONTINUATION frame with no preceding HEADERS
    cont = AwsHTTP._h2_encode_frame_prefix(UInt32(0), UInt8(AwsHTTP.H2FrameType.CONTINUATION),
        AwsHTTP.H2_FRAME_F_END_HEADERS, UInt32(1))
    err, _, _ = AwsHTTP.h2_decode_frame(dec, cont, 1)
    @test AwsHTTP.h2err_failed(err)
    @test err.h2_code == AwsHTTP.Http2ErrorCode.PROTOCOL_ERROR
end

@testset "H2 decoder - RST_STREAM wrong payload size" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true

    # RST_STREAM with 3 bytes payload (should be 4)
    bad = UInt8[
        0x00, 0x00, 0x03,       # Length = 3
        0x03,                    # RST_STREAM
        0x00,
        0x00, 0x00, 0x00, 0x01, # Stream ID = 1
        0xFE, 0xED, 0xBE,       # Only 3 bytes
    ]
    err, _, _ = AwsHTTP.h2_decode_frame(dec, bad, 1)
    @test AwsHTTP.h2err_failed(err)
    @test err.h2_code == AwsHTTP.Http2ErrorCode.FRAME_SIZE_ERROR
end

@testset "H2 settings header encode/decode roundtrip" begin
    settings = [
        AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.ENABLE_PUSH, UInt32(0)),
        AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.MAX_FRAME_SIZE, UInt32(65536)),
    ]
    status, encoded = AwsHTTP.h2_encode_http2_settings_header(settings)
    @test status == Reseau.OP_SUCCESS
    @test !isempty(encoded)

    status2, decoded = AwsHTTP.h2_decode_http2_settings_header(encoded)
    @test status2 == Reseau.OP_SUCCESS
    @test length(decoded) == 2
    @test decoded[1].id == AwsHTTP.Http2SettingsId.ENABLE_PUSH
    @test decoded[1].value == 0
    @test decoded[2].id == AwsHTTP.Http2SettingsId.MAX_FRAME_SIZE
    @test decoded[2].value == 65536
end

@testset "H2 settings header invalid base64" begin
    status, _ = AwsHTTP.h2_decode_http2_settings_header(Vector{UInt8}(codeunits("\$\$\$")))
    @test status == Reseau.OP_ERR
end

@testset "H2 settings header invalid length" begin
    # 5 bytes is not a multiple of 6
    bad_b64 = AwsHTTP.base64url_encode(UInt8[0x00, 0x01, 0x00, 0x00, 0x01])
    status, _ = AwsHTTP.h2_decode_http2_settings_header(bad_b64)
    @test status == Reseau.OP_ERR
end

@testset "H2 settings header invalid value" begin
    # ENABLE_PUSH (0x02) with value 2 (invalid)
    binary = UInt8[0x00, 0x02, 0x00, 0x00, 0x00, 0x02]
    b64 = AwsHTTP.base64url_encode(binary)
    status, _ = AwsHTTP.h2_decode_http2_settings_header(b64)
    @test status == Reseau.OP_ERR
end

@testset "H2 decoder - frame exceeds max_frame_size" begin
    dec = AwsHTTP.h2_decoder_new(is_server=false)
    dec.connection_preface_complete = true
    dec.max_frame_size = UInt32(10)  # Tiny max

    # Frame with 11 bytes payload
    frame_data = vcat(
        AwsHTTP._h2_encode_frame_prefix(UInt32(11), UInt8(AwsHTTP.H2FrameType.DATA),
            0x00, UInt32(1)),
        zeros(UInt8, 11))

    err, _, _ = AwsHTTP.h2_decode_frame(dec, frame_data, 1)
    @test AwsHTTP.h2err_failed(err)
    @test err.h2_code == AwsHTTP.Http2ErrorCode.FRAME_SIZE_ERROR
end

# ─── Phase 8: HTTP/2 Connection ───

@testset "H2 connection - client construction" begin
    conn = AwsHTTP.h2_connection_new(is_client=true)
    @test conn.is_client == true
    @test conn.http_version == AwsHTTP.HttpVersion.HTTP_2
    @test conn.next_stream_id == UInt32(1)
    @test conn.is_open == true
    @test conn.new_requests_allowed == true
    @test !conn.goaway_sent
    @test !conn.goaway_received
    @test AwsHTTP.http_connection_is_client(conn)
    @test AwsHTTP.http_connection_is_open(conn)
    @test AwsHTTP.http_connection_get_version(conn) == AwsHTTP.HttpVersion.HTTP_2
end

@testset "H2 connection - server construction" begin
    conn = AwsHTTP.h2_connection_new(is_client=false)
    @test conn.is_client == false
    @test conn.next_stream_id == UInt32(2)
end

@testset "H2 connection - close and stop_new_requests" begin
    conn = AwsHTTP.h2_connection_new()
    @test AwsHTTP.http_connection_new_requests_allowed(conn)

    AwsHTTP.http_connection_stop_new_requests(conn)
    @test !AwsHTTP.http_connection_new_requests_allowed(conn)
    @test AwsHTTP.http_connection_is_open(conn)  # still open

    AwsHTTP.http_connection_close(conn)
    @test !AwsHTTP.http_connection_is_open(conn)
end

@testset "H2 connection - client preface" begin
    conn = AwsHTTP.h2_connection_new(is_client=true)
    status, preface = AwsHTTP.h2_connection_get_preface(conn)
    @test status == Reseau.OP_SUCCESS
    @test !isempty(preface)
    # Should start with client magic string
    @test preface[1:24] == Vector{UInt8}(AwsHTTP.H2_CONNECTION_PREFACE_CLIENT)
    # Followed by SETTINGS frame (type byte at offset 24+4 should be 0x04)
    @test preface[28] == UInt8(AwsHTTP.H2FrameType.SETTINGS)
    @test conn.connection_preface_sent
end

@testset "H2 connection - server preface" begin
    conn = AwsHTTP.h2_connection_new(is_client=false)
    status, preface = AwsHTTP.h2_connection_get_preface(conn)
    @test status == Reseau.OP_SUCCESS
    # Server preface starts with SETTINGS directly (no magic string)
    @test preface[4] == UInt8(AwsHTTP.H2FrameType.SETTINGS)
end

@testset "H2 connection - settings initial values" begin
    conn = AwsHTTP.h2_connection_new()
    local_settings = AwsHTTP.h2_connection_get_local_settings(conn)
    @test local_settings[AwsHTTP.Http2SettingsId.HEADER_TABLE_SIZE] == 4096
    @test local_settings[AwsHTTP.Http2SettingsId.ENABLE_PUSH] == 1
    @test local_settings[AwsHTTP.Http2SettingsId.MAX_FRAME_SIZE] == 16384
    @test local_settings[AwsHTTP.Http2SettingsId.INITIAL_WINDOW_SIZE] == 65535
end

@testset "H2 connection - change settings" begin
    conn = AwsHTTP.h2_connection_new()
    settings = [AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.MAX_CONCURRENT_STREAMS, UInt32(100))]
    future = AwsHTTP.h2_connection_change_settings!(conn, settings)
    @test (@atomic future.set) == Int8(0)
    @test length(conn.pending_settings_queue) == 1
    @test !isempty(conn.outgoing_frames)

    # Simulate receiving ACK
    err = AwsHTTP.h2_connection_on_settings_ack!(conn)
    @test AwsHTTP.h2err_success(err)
    @test isempty(conn.pending_settings_queue)
    @test wait(future) == Reseau.OP_SUCCESS
    @test conn.settings_local[AwsHTTP.Http2SettingsId.MAX_CONCURRENT_STREAMS] == 100
end

@testset "H2 connection - settings ACK without pending fails" begin
    conn = AwsHTTP.h2_connection_new()
    err = AwsHTTP.h2_connection_on_settings_ack!(conn)
    @test AwsHTTP.h2err_failed(err)
    @test err.h2_code == AwsHTTP.Http2ErrorCode.PROTOCOL_ERROR
end

@testset "H2 connection - receive remote settings" begin
    conn = AwsHTTP.h2_connection_new()
    changed_ref = Ref{Vector{AwsHTTP.Http2Setting}}(AwsHTTP.Http2Setting[])
    conn.on_remote_settings_change = (s) -> begin changed_ref[] = s end

    settings = [AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.MAX_FRAME_SIZE, UInt32(32768))]
    err = AwsHTTP.h2_connection_on_settings_received!(conn, settings)
    @test AwsHTTP.h2err_success(err)
    @test conn.settings_remote[AwsHTTP.Http2SettingsId.MAX_FRAME_SIZE] == 32768
    # Should have queued SETTINGS ACK
    @test !isempty(conn.outgoing_high_priority)
    # Callback should have been invoked
    @test length(changed_ref[]) == 1
end

@testset "H2 connection - GOAWAY send and receive" begin
    conn = AwsHTTP.h2_connection_new()
    goaway_ref = Ref{Tuple{UInt32, UInt32}}((UInt32(0), UInt32(0)))
    conn.on_goaway_received = (last_id, err_code, debug) -> begin goaway_ref[] = (last_id, err_code) end

    # Send GOAWAY
    status = AwsHTTP.h2_connection_send_goaway!(conn; error_code=UInt32(0))
    @test status == Reseau.OP_SUCCESS
    @test conn.goaway_sent
    @test !isempty(conn.outgoing_high_priority)

    sent, last_id, err_code = AwsHTTP.h2_connection_get_sent_goaway(conn)
    @test sent
    @test err_code == 0

    # Receive GOAWAY
    err = AwsHTTP.h2_connection_on_goaway_received!(conn, UInt32(5), UInt32(0x02), UInt8[])
    @test AwsHTTP.h2err_success(err)
    @test conn.goaway_received
    @test !conn.new_requests_allowed
    @test goaway_ref[] == (UInt32(5), UInt32(0x02))

    recv, last_id2, err_code2 = AwsHTTP.h2_connection_get_received_goaway(conn)
    @test recv
    @test last_id2 == 5
    @test err_code2 == 0x02
end

@testset "H2 connection - GOAWAY last_stream_id must not increase" begin
    conn = AwsHTTP.h2_connection_new()

    err1 = AwsHTTP.h2_connection_on_goaway_received!(conn, UInt32(10), UInt32(0), UInt8[])
    @test AwsHTTP.h2err_success(err1)

    # Second GOAWAY with higher last_stream_id should fail
    err2 = AwsHTTP.h2_connection_on_goaway_received!(conn, UInt32(20), UInt32(0), UInt8[])
    @test AwsHTTP.h2err_failed(err2)

    # Lower is fine
    err3 = AwsHTTP.h2_connection_on_goaway_received!(conn, UInt32(5), UInt32(0), UInt8[])
    @test AwsHTTP.h2err_success(err3)
end

@testset "H2 connection - PING send and ACK" begin
    conn = AwsHTTP.h2_connection_new()
    opaque = UInt8[1,2,3,4,5,6,7,8]
    future = AwsHTTP.h2_connection_send_ping!(conn, opaque)
    @test (@atomic future.set) == Int8(0)
    @test length(conn.pending_pings) == 1

    # Simulate receiving ACK
    err = AwsHTTP.h2_connection_on_ping_ack!(conn, opaque)
    @test AwsHTTP.h2err_success(err)
    @test isempty(conn.pending_pings)
    rtt, ping_error = wait(future)
    @test ping_error == Reseau.OP_SUCCESS
    @test rtt > 0  # should have some RTT
end

@testset "H2 connection - PING ACK without pending fails" begin
    conn = AwsHTTP.h2_connection_new()
    err = AwsHTTP.h2_connection_on_ping_ack!(conn, zeros(UInt8, 8))
    @test AwsHTTP.h2err_failed(err)
end

@testset "H2 connection - PING ACK mismatch fails" begin
    conn = AwsHTTP.h2_connection_new()
    _ = AwsHTTP.h2_connection_send_ping!(conn, UInt8[1,2,3,4,5,6,7,8])
    err = AwsHTTP.h2_connection_on_ping_ack!(conn, UInt8[8,7,6,5,4,3,2,1])
    @test AwsHTTP.h2err_failed(err)
end

@testset "H2 connection - receive PING sends ACK" begin
    conn = AwsHTTP.h2_connection_new()
    err = AwsHTTP.h2_connection_on_ping!(conn, UInt8[1,2,3,4,5,6,7,8])
    @test AwsHTTP.h2err_success(err)
    @test !isempty(conn.outgoing_high_priority)
end

@testset "H2 connection - flow control window update" begin
    conn = AwsHTTP.h2_connection_new()
    old_window = conn.window_size_self

    status = AwsHTTP.h2_connection_update_window!(conn, UInt32(1000))
    @test status == Reseau.OP_SUCCESS
    @test conn.window_size_self == old_window + 1000
    @test !isempty(conn.outgoing_frames)
end

@testset "H2 connection - window update overflow protection" begin
    conn = AwsHTTP.h2_connection_new()
    conn.window_size_self = Int64(AwsHTTP.H2_WINDOW_UPDATE_MAX) - 100
    # Trying to add 200 would overflow
    status = AwsHTTP.h2_connection_update_window!(conn, UInt32(200))
    @test status == Reseau.OP_ERR
end

@testset "H2 connection - decode dispatches SETTINGS" begin
    # Client connection
    conn = AwsHTTP.h2_connection_new(is_client=true)
    conn.decoder.connection_preface_complete = true

    # Encode a SETTINGS frame with MAX_FRAME_SIZE=32768
    settings = [AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.MAX_FRAME_SIZE, UInt32(32768))]
    _, frame_data = AwsHTTP.h2_encode_settings(settings)

    err, stream_frames = AwsHTTP.h2_connection_decode!(conn, frame_data)
    @test AwsHTTP.h2err_success(err)
    @test isempty(stream_frames)  # SETTINGS is connection-level
    @test conn.settings_remote[AwsHTTP.Http2SettingsId.MAX_FRAME_SIZE] == 32768
    # Should have queued SETTINGS ACK
    @test !isempty(conn.outgoing_high_priority)
end

@testset "H2 connection - decode dispatches PING" begin
    conn = AwsHTTP.h2_connection_new(is_client=true)
    conn.decoder.connection_preface_complete = true

    opaque = UInt8[0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]
    _, frame_data = AwsHTTP.h2_encode_ping(opaque)

    err, stream_frames = AwsHTTP.h2_connection_decode!(conn, frame_data)
    @test AwsHTTP.h2err_success(err)
    @test isempty(stream_frames)
    # Should have queued PING ACK
    @test !isempty(conn.outgoing_high_priority)
end

@testset "H2 connection - decode dispatches GOAWAY" begin
    conn = AwsHTTP.h2_connection_new(is_client=true)
    conn.decoder.connection_preface_complete = true

    _, frame_data = AwsHTTP.h2_encode_goaway(UInt32(7), UInt32(0); debug_data=UInt8[])

    err, stream_frames = AwsHTTP.h2_connection_decode!(conn, frame_data)
    @test AwsHTTP.h2err_success(err)
    @test conn.goaway_received
    @test conn.goaway_received_last_stream_id == 7
end

@testset "H2 connection - decode passes DATA to caller" begin
    conn = AwsHTTP.h2_connection_new(is_client=true)
    conn.decoder.connection_preface_complete = true

    _, frame_data = AwsHTTP.h2_encode_data(UInt32(1), UInt8[0x01, 0x02, 0x03]; end_stream=true)

    err, stream_frames = AwsHTTP.h2_connection_decode!(conn, frame_data)
    @test AwsHTTP.h2err_success(err)
    @test length(stream_frames) == 1
    @test stream_frames[1].frame_type == AwsHTTP.H2FrameType.DATA
    @test stream_frames[1].data == UInt8[0x01, 0x02, 0x03]
    @test stream_frames[1].end_stream == true
end

@testset "H2 connection - decode connection-level WINDOW_UPDATE" begin
    conn = AwsHTTP.h2_connection_new(is_client=true)
    conn.decoder.connection_preface_complete = true
    old_peer_window = conn.window_size_peer

    _, frame_data = AwsHTTP.h2_encode_window_update(UInt32(0), UInt32(5000))

    err, stream_frames = AwsHTTP.h2_connection_decode!(conn, frame_data)
    @test AwsHTTP.h2err_success(err)
    @test conn.window_size_peer == old_peer_window + 5000
end

@testset "H2 connection - get_outgoing_frames! priority ordering" begin
    conn = AwsHTTP.h2_connection_new()

    # Queue normal frame
    push!(conn.outgoing_frames, UInt8[0x01, 0x02])
    # Queue high-priority frame
    push!(conn.outgoing_high_priority, UInt8[0xAA, 0xBB])

    output = AwsHTTP.h2_connection_get_outgoing_frames!(conn)
    @test length(output) == 4
    # High priority should come first
    @test output[1:2] == UInt8[0xAA, 0xBB]
    @test output[3:4] == UInt8[0x01, 0x02]
    # Queues should be empty
    @test isempty(conn.outgoing_frames)
    @test isempty(conn.outgoing_high_priority)
end

@testset "H2 connection - full client/server preface exchange" begin
    client = AwsHTTP.h2_connection_new(is_client=true)
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Client generates preface
    status_c, client_preface = AwsHTTP.h2_connection_get_preface(client)
    @test status_c == Reseau.OP_SUCCESS

    # Server generates preface
    status_s, server_preface = AwsHTTP.h2_connection_get_preface(server)
    @test status_s == Reseau.OP_SUCCESS

    # Server decodes client preface (includes magic + SETTINGS)
    err_s, frames_s = AwsHTTP.h2_connection_decode!(server, client_preface)
    @test AwsHTTP.h2err_success(err_s)
    @test server.decoder.connection_preface_complete

    # Client decodes server preface (SETTINGS)
    err_c, frames_c = AwsHTTP.h2_connection_decode!(client, server_preface)
    @test AwsHTTP.h2err_success(err_c)

    # Both should have queued SETTINGS ACK
    server_out = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    client_out = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    @test !isempty(server_out)
    @test !isempty(client_out)
end

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 9: HTTP/2 Streams
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Helper: create a connected client/server pair with preface exchanged ───
function _make_h2_pair()
    client = AwsHTTP.h2_connection_new(is_client=true)
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Exchange prefaces
    s1, client_preface = AwsHTTP.h2_connection_get_preface(client)
    s2, server_preface = AwsHTTP.h2_connection_get_preface(server)

    # Server decodes client preface, client decodes server preface
    AwsHTTP.h2_connection_decode!(server, client_preface)
    AwsHTTP.h2_connection_decode!(client, server_preface)

    # Drain ACKs
    AwsHTTP.h2_connection_get_outgoing_frames!(client)
    AwsHTTP.h2_connection_get_outgoing_frames!(server)

    return client, server
end

# Helper: build a simple GET request
function _make_get_request(path="/")
    msg = AwsHTTP.http2_message_new_request()
    AwsHTTP.http_message_set_request_method(msg, "GET")
    AwsHTTP.http_message_set_request_path(msg, path)
    AwsHTTP.http_headers_add(msg.headers, ":scheme", "https")
    AwsHTTP.http_headers_add(msg.headers, ":authority", "example.com")
    return msg
end

# Helper: build a POST request with body
function _make_post_request(path="/", body=UInt8[])
    msg = AwsHTTP.http2_message_new_request()
    AwsHTTP.http_message_set_request_method(msg, "POST")
    AwsHTTP.http_message_set_request_path(msg, path)
    AwsHTTP.http_headers_add(msg.headers, ":scheme", "https")
    AwsHTTP.http_headers_add(msg.headers, ":authority", "example.com")
    if !isempty(body)
        AwsHTTP.http_message_set_body_stream(msg, body)
    end
    return msg
end

# Helper: build a simple 200 OK response
function _make_200_response(; body=nothing)
    msg = AwsHTTP.http2_message_new_response()
    AwsHTTP.http_message_set_response_status(msg, 200)
    if body !== nothing
        AwsHTTP.http_message_set_body_stream(msg, body)
    end
    return msg
end

@testset "H2 stream - state enum and string conversion" begin
    @test AwsHTTP.h2_stream_state_to_str(AwsHTTP.H2StreamState.IDLE) == "IDLE"
    @test AwsHTTP.h2_stream_state_to_str(AwsHTTP.H2StreamState.OPEN) == "OPEN"
    @test AwsHTTP.h2_stream_state_to_str(AwsHTTP.H2StreamState.HALF_CLOSED_LOCAL) == "HALF_CLOSED_LOCAL"
    @test AwsHTTP.h2_stream_state_to_str(AwsHTTP.H2StreamState.HALF_CLOSED_REMOTE) == "HALF_CLOSED_REMOTE"
    @test AwsHTTP.h2_stream_state_to_str(AwsHTTP.H2StreamState.CLOSED) == "CLOSED"
end

@testset "H2 stream - client request creation (GET)" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request("/index.html")
    opts = AwsHTTP.HttpMakeRequestOptions(request=msg)
    stream = AwsHTTP.h2_stream_new_request(client, opts)
    @test stream !== nothing
    @test stream.is_client == true
    @test stream.state == AwsHTTP.H2StreamState.IDLE
    @test stream.api_state == AwsHTTP.H2StreamApiState.INIT
    @test stream.body_state == AwsHTTP.H2StreamBodyState.NONE
    @test stream.request_method == AwsHTTP.HttpMethod.GET
    @test isempty(stream.outgoing_writes)
end

@testset "H2 stream - client request creation (POST with body)" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}("Hello, world!")
    msg = _make_post_request("/submit", body)
    opts = AwsHTTP.HttpMakeRequestOptions(request=msg)
    stream = AwsHTTP.h2_stream_new_request(client, opts)
    @test stream !== nothing
    @test stream.body_state == AwsHTTP.H2StreamBodyState.ONGOING
    @test length(stream.outgoing_writes) == 1
    @test stream.outgoing_writes[1].end_stream == true
    @test stream.outgoing_writes[1].data == Vector{UInt8}("Hello, world!")
end

@testset "H2 stream - activate GET request" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request("/test")
    opts = AwsHTTP.HttpMakeRequestOptions(request=msg)
    stream = AwsHTTP.h2_stream_new_request(client, opts)

    status, body_state = AwsHTTP.h2_stream_activate!(stream, client)
    @test status == AwsHTTP.OP_SUCCESS
    @test body_state == AwsHTTP.H2StreamBodyState.NONE
    @test stream.id == UInt32(1)
    @test stream.api_state == AwsHTTP.H2StreamApiState.ACTIVE
    # GET with no body → HALF_CLOSED_LOCAL (END_STREAM sent with HEADERS)
    @test stream.state == AwsHTTP.H2StreamState.HALF_CLOSED_LOCAL
    @test stream.end_stream_sent == true
    @test !isempty(stream.outgoing_frames)
    # Stream registered in connection
    @test haskey(client.active_streams, UInt32(1))
end

@testset "H2 stream - activate POST request" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}("data")
    msg = _make_post_request("/upload", body)
    opts = AwsHTTP.HttpMakeRequestOptions(request=msg)
    stream = AwsHTTP.h2_stream_new_request(client, opts)

    status, body_state = AwsHTTP.h2_stream_activate!(stream, client)
    @test status == AwsHTTP.OP_SUCCESS
    @test body_state == AwsHTTP.H2StreamBodyState.ONGOING
    @test stream.id == UInt32(1)
    # POST with body → OPEN (END_STREAM not yet sent)
    @test stream.state == AwsHTTP.H2StreamState.OPEN
    @test stream.end_stream_sent == false
end

@testset "H2 stream - stream ID assignment" begin
    client, _ = _make_h2_pair()

    # First stream gets ID 1
    msg1 = _make_get_request("/a")
    s1 = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg1))
    AwsHTTP.h2_stream_activate!(s1, client)
    @test s1.id == UInt32(1)

    # Second stream gets ID 3
    msg2 = _make_get_request("/b")
    s2 = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg2))
    AwsHTTP.h2_stream_activate!(s2, client)
    @test s2.id == UInt32(3)

    # Third stream gets ID 5
    msg3 = _make_get_request("/c")
    s3 = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg3))
    AwsHTTP.h2_stream_activate!(s3, client)
    @test s3.id == UInt32(5)

    @test client.next_stream_id == UInt32(7)
end

@testset "H2 stream - lifecycle" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    @test stream !== nothing
    @test stream.is_client == true
end

@testset "H2 stream - complete invokes callbacks" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    completed = Ref(false)
    error_received = Ref(-1)
    opts = AwsHTTP.HttpMakeRequestOptions(
        request=msg,
        on_complete=(stream, err, ud) -> begin
            completed[] = true
            error_received[] = err
        end,
    )
    stream = AwsHTTP.h2_stream_new_request(client, opts)
    AwsHTTP.h2_stream_activate!(stream, client)

    AwsHTTP.h2_stream_complete!(stream, 0)
    @test completed[]
    @test error_received[] == 0
    @test stream.api_state == AwsHTTP.H2StreamApiState.COMPLETE
    @test stream.state == AwsHTTP.H2StreamState.CLOSED
    # Should be unregistered from connection
    @test !haskey(client.active_streams, stream.id)
end

@testset "H2 stream - RST_STREAM send" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    status = AwsHTTP.h2_stream_reset!(stream, UInt32(AwsHTTP.Http2ErrorCode.CANCEL))
    @test status == AwsHTTP.OP_SUCCESS
    @test stream.state == AwsHTTP.H2StreamState.CLOSED
    @test stream.sent_reset_error_code == Int64(AwsHTTP.Http2ErrorCode.CANCEL)
    @test !isempty(stream.outgoing_frames)
end

@testset "H2 stream - cancel sends RST_STREAM CANCEL" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    status = AwsHTTP.h2_stream_cancel!(stream)
    @test status == AwsHTTP.OP_SUCCESS
    @test stream.sent_reset_error_code == Int64(AwsHTTP.Http2ErrorCode.CANCEL)
end

@testset "H2 stream - RST_STREAM receive" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    err = AwsHTTP.h2_stream_on_rst_stream!(stream, UInt32(AwsHTTP.Http2ErrorCode.REFUSED_STREAM))
    @test AwsHTTP.h2err_success(err)
    @test stream.state == AwsHTTP.H2StreamState.CLOSED
    @test stream.received_reset_error_code == Int64(AwsHTTP.Http2ErrorCode.REFUSED_STREAM)
end

@testset "H2 stream - RST_STREAM NO_ERROR after END_STREAM received (RFC 7540 §8.1)" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Simulate receiving END_STREAM
    AwsHTTP.h2_stream_on_end_stream_received!(stream)
    @test stream.end_stream_received == true

    # NO_ERROR RST after complete response should be silently discarded
    err = AwsHTTP.h2_stream_on_rst_stream!(stream, UInt32(AwsHTTP.Http2ErrorCode.NO_ERROR))
    @test AwsHTTP.h2err_success(err)
    @test stream.state == AwsHTTP.H2StreamState.CLOSED
end

@testset "H2 stream - priority update" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    priority = AwsHTTP.Http2PrioritySettings(UInt32(0), false, UInt16(32))
    status = AwsHTTP.h2_stream_update_priority!(stream, priority)
    @test status == AwsHTTP.OP_SUCCESS
    @test stream.priority.weight == UInt16(32)
    @test !isempty(stream.outgoing_frames)
end

@testset "H2 stream - flow control window update" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}("data")
    msg = _make_post_request("/", body)
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Manual window update
    status = AwsHTTP.h2_stream_update_window!(stream, UInt32(1000))
    @test status == AwsHTTP.OP_SUCCESS
    # Stream should have a WINDOW_UPDATE frame queued
    frames_before = length(stream.outgoing_frames)
    @test frames_before > 0
end

@testset "H2 stream - window_size_change overflow protection" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Try to overflow the peer window
    err = AwsHTTP.h2_stream_window_size_change!(stream, Int32(typemax(Int32)), false)
    @test AwsHTTP.h2err_failed(err)
end

@testset "H2 stream - WINDOW_UPDATE received" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    old_peer = stream.window_size_peer
    err, resumed = AwsHTTP.h2_stream_on_window_update!(stream, UInt32(5000))
    @test AwsHTTP.h2err_success(err)
    @test stream.window_size_peer == old_peer + Int32(5000)

    # Zero increment is protocol error
    err2, _ = AwsHTTP.h2_stream_on_window_update!(stream, UInt32(0))
    @test AwsHTTP.h2err_failed(err2)
end

@testset "H2 stream - WINDOW_UPDATE overflow protection" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Try to overflow with a huge increment
    err, _ = AwsHTTP.h2_stream_on_window_update!(stream, UInt32(AwsHTTP.H2_WINDOW_UPDATE_MAX))
    @test AwsHTTP.h2err_failed(err)
end

@testset "H2 stream - WINDOW_UPDATE resume detection" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}("data")
    msg = _make_post_request("/", body)
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Manually exhaust window
    stream.window_size_peer = Int32(0)

    # Window update should report resumed
    err, resumed = AwsHTTP.h2_stream_on_window_update!(stream, UInt32(1000))
    @test AwsHTTP.h2err_success(err)
    @test resumed == true
end

@testset "H2 stream - DATA frame encoding" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}("Hello, HTTP/2!")
    msg = _make_post_request("/upload", body)
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Clear HEADERS frame
    AwsHTTP.h2_stream_get_outgoing_frames!(stream)

    # Encode DATA
    old_peer_window = stream.window_size_peer
    old_conn_window = client.window_size_peer
    status, encode_status = AwsHTTP.h2_stream_encode_data_frame!(stream, client)
    @test status == AwsHTTP.OP_SUCCESS
    @test encode_status == AwsHTTP.H2DataEncodeStatus.COMPLETE
    @test !isempty(stream.outgoing_frames)
    @test stream.end_stream_sent == true

    # Flow control windows should be decremented
    @test stream.window_size_peer == old_peer_window - Int32(length(body))
    @test client.window_size_peer == old_conn_window - Int64(length(body))
end

@testset "H2 stream - DATA encoding with flow control stall" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}("some data")
    msg = _make_post_request("/", body)
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Exhaust stream window
    stream.window_size_peer = Int32(0)

    # Should stall
    status, encode_status = AwsHTTP.h2_stream_encode_data_frame!(stream, client)
    @test status == AwsHTTP.OP_SUCCESS
    @test encode_status == AwsHTTP.H2DataEncodeStatus.ONGOING_WINDOW_STALL
end

@testset "H2 stream - DATA encoding partial write" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}(collect(0x00:0xFF))  # 256 bytes
    msg = _make_post_request("/", body)
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Restrict window to force partial write
    stream.window_size_peer = Int32(100)

    status, encode_status = AwsHTTP.h2_stream_encode_data_frame!(stream, client)
    @test status == AwsHTTP.OP_SUCCESS
    @test encode_status == AwsHTTP.H2DataEncodeStatus.ONGOING

    # Remaining data should be in the write queue
    @test length(stream.outgoing_writes) == 1
    @test length(stream.outgoing_writes[1].data) == 156  # 256 - 100
end

@testset "H2 stream - trailing headers after body" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}("body data")
    msg = _make_post_request("/", body)
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Add trailing headers
    trailers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(trailers, "x-checksum", "abc123")
    status = AwsHTTP.h2_stream_add_trailing_headers!(stream, trailers)
    @test status == AwsHTTP.OP_SUCCESS
    @test stream.outgoing_trailing_headers !== nothing

    # The write should NOT have end_stream anymore since trailers will carry it
    # Clear HEADERS frame
    AwsHTTP.h2_stream_get_outgoing_frames!(stream)

    # Encode DATA (should not set END_STREAM since trailers follow)
    s, es = AwsHTTP.h2_stream_encode_data_frame!(stream, client)
    @test s == AwsHTTP.OP_SUCCESS
    @test stream.end_stream_sent == true  # trailing HEADERS carry END_STREAM
    @test stream.outgoing_trailing_headers === nothing  # sent
end

@testset "H2 stream - manual write not enabled error" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Stream is not in manual write mode
    status = AwsHTTP.h2_stream_write_data!(stream, UInt8[])
    @test status != AwsHTTP.OP_SUCCESS
end

@testset "H2 stream - incoming HEADERS" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    received_headers = Ref(AwsHTTP.HttpHeader[])
    received_block = Ref(AwsHTTP.HttpHeaderBlock.MAIN)
    opts = AwsHTTP.HttpMakeRequestOptions(
        request=msg,
        on_response_headers=(stream, bt, hdrs, ud) -> begin
            received_headers[] = hdrs
            received_block[] = bt
            return 0
        end,
    )
    stream = AwsHTTP.h2_stream_new_request(client, opts)
    AwsHTTP.h2_stream_activate!(stream, client)

    # Simulate receiving response headers
    headers = [
        AwsHTTP.HttpHeader(":status", "200"),
        AwsHTTP.HttpHeader("content-type", "text/html"),
    ]
    err = AwsHTTP.h2_stream_on_headers!(stream, headers, AwsHTTP.HttpHeaderBlock.MAIN, false)
    @test AwsHTTP.h2err_success(err)
    @test stream.response_status == 200
    @test length(received_headers[]) == 2

    # End of header block
    err2 = AwsHTTP.h2_stream_on_headers_end!(stream, AwsHTTP.HttpHeaderBlock.MAIN, false)
    @test AwsHTTP.h2err_success(err2)
    @test stream.received_main_headers == true
end

@testset "H2 stream - incoming DATA (manual window)" begin
    # Use manual window management so auto-update doesn't replenish
    client = AwsHTTP.h2_connection_new(is_client=true, manual_window_management=true)
    server = AwsHTTP.h2_connection_new(is_client=false)
    s1, cp = AwsHTTP.h2_connection_get_preface(client)
    s2, sp = AwsHTTP.h2_connection_get_preface(server)
    AwsHTTP.h2_connection_decode!(server, cp)
    AwsHTTP.h2_connection_decode!(client, sp)
    AwsHTTP.h2_connection_get_outgoing_frames!(client)
    AwsHTTP.h2_connection_get_outgoing_frames!(server)

    msg = _make_get_request()
    received_body = UInt8[]
    opts = AwsHTTP.HttpMakeRequestOptions(
        request=msg,
        on_response_body=(stream, data, ud) -> begin
            append!(received_body, data)
            return 0
        end,
    )
    stream = AwsHTTP.h2_stream_new_request(client, opts)
    AwsHTTP.h2_stream_activate!(stream, client)

    # First, receive headers
    stream.received_main_headers = true

    # Then receive DATA
    data = Vector{UInt8}("Hello from server!")
    old_window = stream.window_size_self
    err = AwsHTTP.h2_stream_on_data!(stream, data, UInt32(length(data)), false)
    @test AwsHTTP.h2err_success(err)
    @test received_body == data
    @test stream.incoming_data_length == Int64(length(data))
    @test stream.window_size_self < old_window  # window decremented (not auto-restored)
end

@testset "H2 stream - incoming DATA (auto window update)" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    received_body = UInt8[]
    opts = AwsHTTP.HttpMakeRequestOptions(
        request=msg,
        on_response_body=(stream, data, ud) -> begin
            append!(received_body, data)
            return 0
        end,
    )
    stream = AwsHTTP.h2_stream_new_request(client, opts)
    AwsHTTP.h2_stream_activate!(stream, client)
    stream.received_main_headers = true

    # Auto-mode: after receiving data, window should be replenished via WINDOW_UPDATE
    data = Vector{UInt8}("Hello from server!")
    err = AwsHTTP.h2_stream_on_data!(stream, data, UInt32(length(data)), false)
    @test AwsHTTP.h2err_success(err)
    @test received_body == data
    # Auto-window should have generated a WINDOW_UPDATE frame
    @test !isempty(stream.outgoing_frames)
end

@testset "H2 stream - DATA content-length validation" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)
    stream.received_main_headers = true
    stream.incoming_content_length = Int64(5)

    # Receive exactly 5 bytes
    err = AwsHTTP.h2_stream_on_data!(stream, UInt8[1,2,3,4,5], UInt32(5), true)
    @test AwsHTTP.h2err_success(err)
end

@testset "H2 stream - DATA content-length mismatch" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)
    stream.received_main_headers = true
    stream.incoming_content_length = Int64(10)

    # Receive only 5 bytes then END_STREAM → mismatch
    err = AwsHTTP.h2_stream_on_data!(stream, UInt8[1,2,3,4,5], UInt32(5), true)
    @test AwsHTTP.h2err_failed(err)
end

@testset "H2 stream - DATA flow control error" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)
    stream.received_main_headers = true

    # Set tiny window
    stream.window_size_self = Int32(5)

    # Try to receive more than window allows
    err = AwsHTTP.h2_stream_on_data!(stream, UInt8[1,2,3,4,5,6,7,8,9,10], UInt32(10), false)
    @test AwsHTTP.h2err_failed(err)
end

@testset "H2 stream - state transition: OPEN → HALF_CLOSED_REMOTE on END_STREAM" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}("data")
    msg = _make_post_request("/", body)
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)
    @test stream.state == AwsHTTP.H2StreamState.OPEN

    # Receive END_STREAM
    AwsHTTP.h2_stream_on_end_stream_received!(stream)
    @test stream.state == AwsHTTP.H2StreamState.HALF_CLOSED_REMOTE
end

@testset "H2 stream - state transition: HALF_CLOSED_LOCAL → CLOSED on END_STREAM received" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)
    @test stream.state == AwsHTTP.H2StreamState.HALF_CLOSED_LOCAL

    AwsHTTP.h2_stream_on_end_stream_received!(stream)
    @test stream.state == AwsHTTP.H2StreamState.CLOSED
end

@testset "H2 stream - state transition: HALF_CLOSED_REMOTE → CLOSED on send END_STREAM" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}("data")
    msg = _make_post_request("/", body)
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Receive END_STREAM → HALF_CLOSED_REMOTE
    AwsHTTP.h2_stream_on_end_stream_received!(stream)
    @test stream.state == AwsHTTP.H2StreamState.HALF_CLOSED_REMOTE

    # Send END_STREAM via DATA
    AwsHTTP.h2_stream_get_outgoing_frames!(stream)
    AwsHTTP.h2_stream_encode_data_frame!(stream, client)
    @test stream.state == AwsHTTP.H2StreamState.CLOSED
end

@testset "H2 stream - push promise receive" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    err = AwsHTTP.h2_stream_on_push_promise!(stream, UInt32(2))
    @test AwsHTTP.h2err_success(err)
end

@testset "H2 stream - push promise on IDLE stream is protocol error" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    # Don't activate - stream stays IDLE

    err = AwsHTTP.h2_stream_on_push_promise!(stream, UInt32(2))
    @test AwsHTTP.h2err_failed(err)
end

@testset "H2 stream - push promise stream creation" begin
    client, _ = _make_h2_pair()
    req = _make_get_request("/pushed")
    stream = AwsHTTP.h2_stream_new_push_promise(client, UInt32(2), req)
    @test stream.id == UInt32(2)
    @test stream.state == AwsHTTP.H2StreamState.RESERVED_REMOTE
    @test stream.api_state == AwsHTTP.H2StreamApiState.ACTIVE
end

@testset "H2 stream - server response (no body)" begin
    _, server = _make_h2_pair()

    # Create server-side stream
    handler_opts = AwsHTTP.HttpRequestHandlerOptions(server, nothing, nothing, nothing, nothing, nothing, nothing, nothing)
    stream = AwsHTTP.h2_stream_new_request_handler(server, handler_opts)
    stream.id = UInt32(1)
    stream.state = AwsHTTP.H2StreamState.OPEN
    stream.api_state = AwsHTTP.H2StreamApiState.ACTIVE
    server.active_streams[UInt32(1)] = stream

    # Send 200 response with no body
    resp = _make_200_response()
    status = AwsHTTP.h2_stream_send_response!(stream, server, resp)
    @test status == AwsHTTP.OP_SUCCESS
    @test stream.end_stream_sent == true
    @test stream.state == AwsHTTP.H2StreamState.HALF_CLOSED_LOCAL
    @test !isempty(stream.outgoing_frames)
end

@testset "H2 stream - server response (with body)" begin
    _, server = _make_h2_pair()

    handler_opts = AwsHTTP.HttpRequestHandlerOptions(server, nothing, nothing, nothing, nothing, nothing, nothing, nothing)
    stream = AwsHTTP.h2_stream_new_request_handler(server, handler_opts)
    stream.id = UInt32(1)
    stream.state = AwsHTTP.H2StreamState.OPEN
    stream.api_state = AwsHTTP.H2StreamApiState.ACTIVE
    server.active_streams[UInt32(1)] = stream

    body = Vector{UInt8}("Hello!")
    resp = _make_200_response(body=body)
    status = AwsHTTP.h2_stream_send_response!(stream, server, resp)
    @test status == AwsHTTP.OP_SUCCESS
    @test stream.end_stream_sent == false
    @test stream.body_state == AwsHTTP.H2StreamBodyState.ONGOING
    @test length(stream.outgoing_writes) == 1
end

@testset "H2 stream - server push promise send" begin
    _, server = _make_h2_pair()

    handler_opts = AwsHTTP.HttpRequestHandlerOptions(server, nothing, nothing, nothing, nothing, nothing, nothing, nothing)
    stream = AwsHTTP.h2_stream_new_request_handler(server, handler_opts)
    stream.id = UInt32(1)
    stream.state = AwsHTTP.H2StreamState.OPEN
    stream.api_state = AwsHTTP.H2StreamApiState.ACTIVE
    server.active_streams[UInt32(1)] = stream

    push_headers = AwsHTTP.http_headers_new()
    AwsHTTP.http_headers_add(push_headers, ":method", "GET")
    AwsHTTP.http_headers_add(push_headers, ":path", "/style.css")
    AwsHTTP.http_headers_add(push_headers, ":scheme", "https")
    AwsHTTP.http_headers_add(push_headers, ":authority", "example.com")

    status = AwsHTTP.h2_stream_send_push_promise!(stream, server, UInt32(2), push_headers)
    @test status == AwsHTTP.OP_SUCCESS
    @test !isempty(stream.outgoing_frames)
end

@testset "H2 stream - has_outgoing_data and is_write_stalled" begin
    client, _ = _make_h2_pair()
    body = Vector{UInt8}("data")
    msg = _make_post_request("/", body)
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    @test AwsHTTP.h2_stream_has_outgoing_data(stream) == true

    # Not stalled (window is positive)
    @test AwsHTTP.h2_stream_is_write_stalled(stream, client) == false

    # Stall the window
    stream.window_size_peer = Int32(0)
    @test AwsHTTP.h2_stream_is_write_stalled(stream, client) == true
end

@testset "H2 stream - SETTINGS INITIAL_WINDOW_SIZE adjusts stream windows" begin
    client, server = _make_h2_pair()

    # Create and activate a stream
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)
    initial_peer = stream.window_size_peer

    # Server sends SETTINGS with new INITIAL_WINDOW_SIZE
    new_settings = [AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.INITIAL_WINDOW_SIZE, UInt32(32768))]
    err = AwsHTTP.h2_connection_on_settings_received!(client, new_settings)
    @test AwsHTTP.h2err_success(err)

    # Stream window should be adjusted by delta
    delta = Int32(32768) - Int32(AwsHTTP.H2_INIT_WINDOW_SIZE)
    @test stream.window_size_peer == initial_peer + delta
end

@testset "H2 stream - H1 to H2 message conversion on request" begin
    client, _ = _make_h2_pair()

    # Create an H1-style request
    msg = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(msg, "GET")
    AwsHTTP.http_message_set_request_path(msg, "/api/data")
    AwsHTTP.http_headers_add(msg.headers, "host", "api.example.com")
    AwsHTTP.http_headers_add(msg.headers, "accept", "application/json")

    opts = AwsHTTP.HttpMakeRequestOptions(request=msg)
    stream = AwsHTTP.h2_stream_new_request(client, opts)
    @test stream !== nothing
    # The outgoing message should be H2 format
    @test stream.outgoing_message.http_version == AwsHTTP.HttpVersion.HTTP_2
end

@testset "H2 stream - collect outgoing frames" begin
    client, _ = _make_h2_pair()
    msg = _make_get_request()
    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=msg))
    AwsHTTP.h2_stream_activate!(stream, client)

    # Should have HEADERS frame
    output = AwsHTTP.h2_stream_get_outgoing_frames!(stream)
    @test !isempty(output)

    # After collection, queue should be empty
    @test isempty(stream.outgoing_frames)
    output2 = AwsHTTP.h2_stream_get_outgoing_frames!(stream)
    @test isempty(output2)
end

@testset "HTTP server - creation with defaults" begin
    opts = AwsHTTP.HttpServerOptions(
        on_incoming_connection = (srv, conn, err, ud) -> nothing,
    )
    @test opts.endpoint_host == "0.0.0.0"
    @test opts.endpoint_port == UInt32(0)
    @test opts.prior_knowledge_http2 == false
    @test opts.manual_window_management == false

    server = AwsHTTP.http_server_new(opts)
    @test server.is_open == true
    @test isempty(server.connections)
    AwsHTTP.http_server_release(server)
    wait(server.destroyed_event)
end

@testset "HTTP server - creation with custom options" begin
    on_conn = (srv, conn, err, ud) -> nothing
    on_destroy = (ud) -> nothing
    opts = AwsHTTP.HttpServerOptions(
        endpoint_host="127.0.0.1",
        endpoint_port=UInt32(0),
        prior_knowledge_http2=true,
        manual_window_management=true,
        server_user_data="my_data",
        on_incoming_connection=on_conn,
        on_destroy_complete=on_destroy,
    )
    @test opts.endpoint_host == "127.0.0.1"
    @test opts.endpoint_port == UInt32(0)
    @test opts.prior_knowledge_http2 == true
    @test opts.manual_window_management == true
    @test opts.server_user_data == "my_data"

    server = AwsHTTP.http_server_new(opts)
    host, port = AwsHTTP.http_server_get_listener_endpoint(server)
    @test host == "127.0.0.1"
    @test port != UInt32(0)
    AwsHTTP.http_server_release(server)
    wait(server.destroyed_event)
end

@testset "HTTP server - release with destroy callback" begin
    destroyed = Ref(false)
    opts = AwsHTTP.HttpServerOptions(
        server_user_data="ctx",
        on_incoming_connection=(srv, conn, err, ud) -> nothing,
        on_destroy_complete=(ud) -> (destroyed[] = true),
    )
    server = AwsHTTP.http_server_new(opts)
    @test server.is_open == true

    AwsHTTP.http_server_release(server)
    @test server.is_open == false
    wait(server.destroyed_event)
    @test destroyed[]
    @test isempty(server.connections)
end

@testset "HTTP server connection options" begin
    opts = AwsHTTP.HttpServerConnectionOptions(
        connection_user_data="conn_ctx",
        on_incoming_request=(conn, ud) -> nothing,
        on_shutdown=(conn, err, ud) -> nothing,
    )
    @test opts.connection_user_data == "conn_ctx"
    @test opts.on_incoming_request !== nothing
    @test opts.on_h2c_upgrade === nothing
end

@testset "HTTP server - connection_is_server" begin
    # H2 client connection → not server
    h2_client = AwsHTTP.h2_connection_new(is_client=true)
    @test AwsHTTP.http_connection_is_server(h2_client) == false

    # H2 server connection → is server
    h2_server = AwsHTTP.h2_connection_new(is_client=false)
    @test AwsHTTP.http_connection_is_server(h2_server) == true
end

@testset "WS opcodes - enum values" begin
    @test UInt8(AwsHTTP.WsOpcode.CONTINUATION) == 0x0
    @test UInt8(AwsHTTP.WsOpcode.TEXT) == 0x1
    @test UInt8(AwsHTTP.WsOpcode.BINARY) == 0x2
    @test UInt8(AwsHTTP.WsOpcode.CLOSE) == 0x8
    @test UInt8(AwsHTTP.WsOpcode.PING) == 0x9
    @test UInt8(AwsHTTP.WsOpcode.PONG) == 0xA
end

@testset "WS opcodes - data vs control classification" begin
    @test AwsHTTP.ws_is_data_frame(UInt8(0x0)) == true   # CONTINUATION
    @test AwsHTTP.ws_is_data_frame(UInt8(0x1)) == true   # TEXT
    @test AwsHTTP.ws_is_data_frame(UInt8(0x2)) == true   # BINARY
    @test AwsHTTP.ws_is_data_frame(UInt8(0x7)) == true   # reserved data
    @test AwsHTTP.ws_is_data_frame(UInt8(0x8)) == false   # CLOSE
    @test AwsHTTP.ws_is_data_frame(UInt8(0x9)) == false   # PING
    @test AwsHTTP.ws_is_data_frame(UInt8(0xA)) == false   # PONG

    @test AwsHTTP.ws_is_control_frame(UInt8(0x8)) == true
    @test AwsHTTP.ws_is_control_frame(UInt8(0x9)) == true
    @test AwsHTTP.ws_is_control_frame(UInt8(0xA)) == true
    @test AwsHTTP.ws_is_control_frame(UInt8(0x0)) == false
    @test AwsHTTP.ws_is_control_frame(UInt8(0x1)) == false

    # Typed overloads
    @test AwsHTTP.ws_is_data_frame(AwsHTTP.WsOpcode.TEXT) == true
    @test AwsHTTP.ws_is_control_frame(AwsHTTP.WsOpcode.PING) == true
end

# --- 11.2: WebSocket encoder ---

@testset "WS encoder - empty unmasked TEXT" begin
    frame = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.TEXT), payload=UInt8[], fin=true)
    encoded = AwsHTTP.ws_encode_frame(frame)
    @test length(encoded) == 2
    @test encoded[1] == 0x81  # FIN + TEXT
    @test encoded[2] == 0x00  # no mask, length 0
end

@testset "WS encoder - small unmasked TEXT" begin
    payload = Vector{UInt8}("Hello")
    frame = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.TEXT), payload=payload, fin=true)
    encoded = AwsHTTP.ws_encode_frame(frame)
    @test length(encoded) == 2 + 5
    @test encoded[1] == 0x81  # FIN + TEXT
    @test encoded[2] == 0x05  # length 5
    @test encoded[3:end] == payload
end

@testset "WS encoder - masked frame (client)" begin
    payload = Vector{UInt8}("Hi")
    key = (0x37, 0xfa, 0x21, 0x3d)
    frame = AwsHTTP.WsFrame(
        opcode=UInt8(AwsHTTP.WsOpcode.TEXT),
        payload=payload,
        fin=true,
        masked=true,
        masking_key=key,
    )
    encoded = AwsHTTP.ws_encode_frame(frame)
    @test length(encoded) == 2 + 4 + 2  # header + mask + payload
    @test (encoded[2] & 0x80) != 0  # MASK bit set
    @test encoded[3:6] == collect(key)
    # Payload is XOR-masked
    @test encoded[7] == payload[1] ⊻ key[1]
    @test encoded[8] == payload[2] ⊻ key[2]
end

@testset "WS encoder - 16-bit extended length" begin
    # Payload of 126 bytes triggers 16-bit length encoding
    payload = rand(UInt8, 126)
    frame = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.BINARY), payload=payload, fin=true)
    encoded = AwsHTTP.ws_encode_frame(frame)
    @test encoded[2] == 126  # 16-bit extended
    ext_len = UInt16(encoded[3]) << 8 | UInt16(encoded[4])
    @test ext_len == 126
    @test encoded[5:end] == payload
end

@testset "WS encoder - 16-bit max length (65535)" begin
    payload = rand(UInt8, 65535)
    frame = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.BINARY), payload=payload, fin=true)
    encoded = AwsHTTP.ws_encode_frame(frame)
    @test encoded[2] == 126
    ext_len = UInt16(encoded[3]) << 8 | UInt16(encoded[4])
    @test ext_len == 65535
    @test encoded[5:end] == payload
end

@testset "WS encoder - 64-bit extended length" begin
    # Payload of 65536 bytes triggers 64-bit length encoding
    payload = rand(UInt8, 65536)
    frame = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.BINARY), payload=payload, fin=true)
    encoded = AwsHTTP.ws_encode_frame(frame)
    @test encoded[2] == 127  # 64-bit extended
    ext_len = UInt64(0)
    for i in 1:8
        ext_len = (ext_len << 8) | UInt64(encoded[2 + i])
    end
    @test ext_len == 65536
    @test encoded[11:end] == payload
end

@testset "WS encoder - FIN=false (fragmentation)" begin
    payload = Vector{UInt8}("part1")
    frame = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.TEXT), payload=payload, fin=false)
    encoded = AwsHTTP.ws_encode_frame(frame)
    @test (encoded[1] & 0x80) == 0  # FIN bit NOT set
    @test (encoded[1] & 0x0F) == 0x1  # TEXT opcode
end

@testset "WS encoder - RSV bits" begin
    frame = AwsHTTP.WsFrame(
        opcode=UInt8(AwsHTTP.WsOpcode.TEXT),
        payload=UInt8[],
        fin=true,
        rsv=(true, false, true),
    )
    encoded = AwsHTTP.ws_encode_frame(frame)
    @test (encoded[1] & 0x40) != 0  # RSV1 set
    @test (encoded[1] & 0x20) == 0  # RSV2 clear
    @test (encoded[1] & 0x10) != 0  # RSV3 set
end

@testset "WS encoder - all opcodes" begin
    for (op, val) in [(AwsHTTP.WsOpcode.CONTINUATION, 0x0),
                      (AwsHTTP.WsOpcode.TEXT, 0x1),
                      (AwsHTTP.WsOpcode.BINARY, 0x2),
                      (AwsHTTP.WsOpcode.CLOSE, 0x8),
                      (AwsHTTP.WsOpcode.PING, 0x9),
                      (AwsHTTP.WsOpcode.PONG, 0xA)]
        frame = AwsHTTP.WsFrame(opcode=UInt8(op), payload=UInt8[], fin=true)
        encoded = AwsHTTP.ws_encode_frame(frame)
        @test (encoded[1] & 0x0F) == val
    end
end

@testset "WS encoder - frame_encoded_size" begin
    # Empty unmasked
    f1 = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.TEXT), payload=UInt8[])
    @test AwsHTTP.ws_frame_encoded_size(f1) == 2

    # Small unmasked
    f2 = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.TEXT), payload=rand(UInt8, 5))
    @test AwsHTTP.ws_frame_encoded_size(f2) == 2 + 5

    # Masked
    f3 = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.TEXT), payload=rand(UInt8, 5), masked=true)
    @test AwsHTTP.ws_frame_encoded_size(f3) == 2 + 4 + 5

    # 16-bit length
    f4 = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.BINARY), payload=rand(UInt8, 200))
    @test AwsHTTP.ws_frame_encoded_size(f4) == 2 + 2 + 200

    # 64-bit length
    f5 = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.BINARY), payload=rand(UInt8, 65536))
    @test AwsHTTP.ws_frame_encoded_size(f5) == 2 + 8 + 65536
end

# --- 11.3: WebSocket decoder ---

@testset "WS decoder - empty unmasked TEXT" begin
    dec = AwsHTTP.ws_decoder_new()
    data = UInt8[0x81, 0x00]  # FIN+TEXT, length 0
    status, frames = AwsHTTP.ws_decoder_process!(dec, data)
    @test status == AwsHTTP.OP_SUCCESS
    @test length(frames) == 1
    @test frames[1].fin == true
    @test frames[1].opcode == UInt8(AwsHTTP.WsOpcode.TEXT)
    @test frames[1].payload_length == 0
    @test isempty(frames[1].payload)
end

@testset "WS decoder - small unmasked TEXT" begin
    dec = AwsHTTP.ws_decoder_new()
    payload = Vector{UInt8}("Hello")
    data = UInt8[0x81, 0x05, payload...]
    status, frames = AwsHTTP.ws_decoder_process!(dec, data)
    @test status == AwsHTTP.OP_SUCCESS
    @test length(frames) == 1
    @test frames[1].payload == payload
    @test frames[1].payload_length == 5
end

@testset "WS decoder - masked frame" begin
    dec = AwsHTTP.ws_decoder_new()
    key = UInt8[0x37, 0xfa, 0x21, 0x3d]
    plain = Vector{UInt8}("Hi")
    masked = [plain[i] ⊻ key[((i-1) % 4) + 1] for i in 1:length(plain)]
    data = UInt8[0x81, 0x80 | UInt8(length(plain)), key..., masked...]
    status, frames = AwsHTTP.ws_decoder_process!(dec, data)
    @test status == AwsHTTP.OP_SUCCESS
    @test length(frames) == 1
    @test frames[1].masked == true
    @test frames[1].payload == plain  # unmasked by decoder
end

@testset "WS decoder - 16-bit extended length" begin
    dec = AwsHTTP.ws_decoder_new()
    payload = rand(UInt8, 200)
    data = UInt8[0x82, 126, UInt8(200 >> 8), UInt8(200 & 0xFF), payload...]
    status, frames = AwsHTTP.ws_decoder_process!(dec, data)
    @test status == AwsHTTP.OP_SUCCESS
    @test length(frames) == 1
    @test frames[1].payload_length == 200
    @test frames[1].payload == payload
end

@testset "WS decoder - 64-bit extended length" begin
    dec = AwsHTTP.ws_decoder_new()
    len = 65536
    payload = rand(UInt8, len)
    len_bytes = UInt8[0, 0, 0, 0, 0, 1, 0, 0]  # 65536 in big-endian
    data = UInt8[0x82, 127, len_bytes..., payload...]
    status, frames = AwsHTTP.ws_decoder_process!(dec, data)
    @test status == AwsHTTP.OP_SUCCESS
    @test length(frames) == 1
    @test frames[1].payload_length == 65536
    @test frames[1].payload == payload
end

@testset "WS decoder - fragmentation (continuation frames)" begin
    dec = AwsHTTP.ws_decoder_new()
    part1 = Vector{UInt8}("Hel")
    part2 = Vector{UInt8}("lo")
    # Frame 1: TEXT, FIN=false
    data1 = UInt8[0x01, UInt8(length(part1)), part1...]
    # Frame 2: CONTINUATION, FIN=true
    data2 = UInt8[0x80, UInt8(length(part2)), part2...]

    status1, frames1 = AwsHTTP.ws_decoder_process!(dec, data1)
    @test status1 == AwsHTTP.OP_SUCCESS
    @test length(frames1) == 1
    @test frames1[1].fin == false
    @test frames1[1].opcode == UInt8(AwsHTTP.WsOpcode.TEXT)

    status2, frames2 = AwsHTTP.ws_decoder_process!(dec, data2)
    @test status2 == AwsHTTP.OP_SUCCESS
    @test length(frames2) == 1
    @test frames2[1].fin == true
    @test frames2[1].opcode == UInt8(AwsHTTP.WsOpcode.CONTINUATION)
    @test frames2[1].payload == part2
end

@testset "WS decoder - control frame between fragments" begin
    dec = AwsHTTP.ws_decoder_new()
    # Frame 1: TEXT, FIN=false
    data1 = UInt8[0x01, 0x01, 0x41]  # "A"
    # Frame 2: PING (control frames can appear mid-fragment)
    data2 = UInt8[0x89, 0x00]
    # Frame 3: CONTINUATION, FIN=true
    data3 = UInt8[0x80, 0x01, 0x42]  # "B"

    status1, _ = AwsHTTP.ws_decoder_process!(dec, data1)
    @test status1 == AwsHTTP.OP_SUCCESS

    status2, frames2 = AwsHTTP.ws_decoder_process!(dec, data2)
    @test status2 == AwsHTTP.OP_SUCCESS
    @test frames2[1].opcode == UInt8(AwsHTTP.WsOpcode.PING)

    status3, frames3 = AwsHTTP.ws_decoder_process!(dec, data3)
    @test status3 == AwsHTTP.OP_SUCCESS
    @test frames3[1].opcode == UInt8(AwsHTTP.WsOpcode.CONTINUATION)
    @test frames3[1].fin == true
end

@testset "WS decoder - error: fragmented control frame" begin
    dec = AwsHTTP.ws_decoder_new()
    # PING with FIN=false — protocol error
    data = UInt8[0x09, 0x00]  # FIN=0, PING
    status, _ = AwsHTTP.ws_decoder_process!(dec, data)
    @test status != AwsHTTP.OP_SUCCESS
end

@testset "WS decoder - error: control frame payload > 125" begin
    dec = AwsHTTP.ws_decoder_new()
    # PING with 16-bit length — protocol error (control frames must be <=125)
    data = UInt8[0x89, 126, 0x00, 0x80]
    status, _ = AwsHTTP.ws_decoder_process!(dec, data)
    @test status != AwsHTTP.OP_SUCCESS
end

@testset "WS decoder - error: unexpected continuation" begin
    dec = AwsHTTP.ws_decoder_new()
    # CONTINUATION without a preceding non-FIN data frame
    data = UInt8[0x80, 0x01, 0x41]
    status, _ = AwsHTTP.ws_decoder_process!(dec, data)
    @test status != AwsHTTP.OP_SUCCESS
end

@testset "WS decoder - error: new data frame mid-fragment" begin
    dec = AwsHTTP.ws_decoder_new()
    # Frame 1: TEXT, FIN=false (start fragment)
    data1 = UInt8[0x01, 0x01, 0x41]
    status1, _ = AwsHTTP.ws_decoder_process!(dec, data1)
    @test status1 == AwsHTTP.OP_SUCCESS

    # Frame 2: TEXT again (should be CONTINUATION) — protocol error
    data2 = UInt8[0x81, 0x01, 0x42]
    status2, _ = AwsHTTP.ws_decoder_process!(dec, data2)
    @test status2 != AwsHTTP.OP_SUCCESS
end

@testset "WS decoder - error: invalid opcode" begin
    dec = AwsHTTP.ws_decoder_new()
    data = UInt8[0x83, 0x00]  # opcode 0x3 is reserved
    status, _ = AwsHTTP.ws_decoder_process!(dec, data)
    @test status != AwsHTTP.OP_SUCCESS
end

@testset "WS decoder - incremental feeding (byte at a time)" begin
    dec = AwsHTTP.ws_decoder_new()
    payload = Vector{UInt8}("Test")
    wire = UInt8[0x81, UInt8(length(payload)), payload...]

    all_frames = AwsHTTP.WsDecodedFrame[]
    for b in wire
        status, frames = AwsHTTP.ws_decoder_process!(dec, UInt8[b])
        @test status == AwsHTTP.OP_SUCCESS
        append!(all_frames, frames)
    end
    @test length(all_frames) == 1
    @test all_frames[1].payload == payload
end

@testset "WS decoder - multiple frames in single buffer" begin
    dec = AwsHTTP.ws_decoder_new()
    p1 = Vector{UInt8}("A")
    p2 = Vector{UInt8}("B")
    data = UInt8[0x81, 0x01, p1..., 0x82, 0x01, p2...]
    status, frames = AwsHTTP.ws_decoder_process!(dec, data)
    @test status == AwsHTTP.OP_SUCCESS
    @test length(frames) == 2
    @test frames[1].opcode == UInt8(AwsHTTP.WsOpcode.TEXT)
    @test frames[1].payload == p1
    @test frames[2].opcode == UInt8(AwsHTTP.WsOpcode.BINARY)
    @test frames[2].payload == p2
end

@testset "WS encoder-decoder roundtrip - unmasked" begin
    dec = AwsHTTP.ws_decoder_new()
    payload = Vector{UInt8}("Hello, WebSocket!")
    frame = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.TEXT), payload=payload, fin=true)
    encoded = AwsHTTP.ws_encode_frame(frame)

    status, frames = AwsHTTP.ws_decoder_process!(dec, encoded)
    @test status == AwsHTTP.OP_SUCCESS
    @test length(frames) == 1
    @test frames[1].payload == payload
    @test frames[1].fin == true
    @test frames[1].opcode == UInt8(AwsHTTP.WsOpcode.TEXT)
end

@testset "WS encoder-decoder roundtrip - masked" begin
    dec = AwsHTTP.ws_decoder_new()
    payload = Vector{UInt8}("Masked data")
    key = (0xAB, 0xCD, 0xEF, 0x01)
    frame = AwsHTTP.WsFrame(
        opcode=UInt8(AwsHTTP.WsOpcode.BINARY),
        payload=payload,
        fin=true,
        masked=true,
        masking_key=key,
    )
    encoded = AwsHTTP.ws_encode_frame(frame)

    status, frames = AwsHTTP.ws_decoder_process!(dec, encoded)
    @test status == AwsHTTP.OP_SUCCESS
    @test length(frames) == 1
    @test frames[1].payload == payload  # decoder unmasks
    @test frames[1].masked == true
end

@testset "WS encoder-decoder roundtrip - 16-bit length" begin
    dec = AwsHTTP.ws_decoder_new()
    payload = rand(UInt8, 300)
    frame = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.BINARY), payload=payload, fin=true)
    encoded = AwsHTTP.ws_encode_frame(frame)

    status, frames = AwsHTTP.ws_decoder_process!(dec, encoded)
    @test status == AwsHTTP.OP_SUCCESS
    @test frames[1].payload == payload
end

@testset "WS encoder-decoder roundtrip - 64-bit length" begin
    dec = AwsHTTP.ws_decoder_new()
    payload = rand(UInt8, 65536)
    frame = AwsHTTP.WsFrame(opcode=UInt8(AwsHTTP.WsOpcode.BINARY), payload=payload, fin=true)
    encoded = AwsHTTP.ws_encode_frame(frame)

    status, frames = AwsHTTP.ws_decoder_process!(dec, encoded)
    @test status == AwsHTTP.OP_SUCCESS
    @test frames[1].payload == payload
end

# --- 11.4: Close status codes ---

@testset "WS close status - valid codes" begin
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1000)) == true  # NORMAL
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1001)) == true  # GOING_AWAY
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1002)) == true  # PROTOCOL_ERROR
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1003)) == true  # UNSUPPORTED_DATA
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1007)) == true  # INVALID_PAYLOAD
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1008)) == true  # POLICY_VIOLATION
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1009)) == true  # MESSAGE_TOO_BIG
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1010)) == true  # EXTENSIONS_NEEDED
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1011)) == true  # INTERNAL_ERROR
    @test AwsHTTP.ws_is_valid_close_status(UInt16(3000)) == true  # private use
    @test AwsHTTP.ws_is_valid_close_status(UInt16(4999)) == true  # private use max
end

@testset "WS close status - invalid codes" begin
    @test AwsHTTP.ws_is_valid_close_status(UInt16(999)) == false   # below range
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1004)) == false  # reserved
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1005)) == false  # NO_STATUS (must not be sent)
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1006)) == false  # ABNORMAL (must not be sent)
    @test AwsHTTP.ws_is_valid_close_status(UInt16(1012)) == false  # unassigned
    @test AwsHTTP.ws_is_valid_close_status(UInt16(2999)) == false  # below private range
    @test AwsHTTP.ws_is_valid_close_status(UInt16(5000)) == false  # above private range
end

@testset "WS close status constants" begin
    @test AwsHTTP.WS_CLOSE_STATUS_NORMAL == UInt16(1000)
    @test AwsHTTP.WS_CLOSE_STATUS_GOING_AWAY == UInt16(1001)
    @test AwsHTTP.WS_CLOSE_STATUS_PROTOCOL_ERROR == UInt16(1002)
    @test AwsHTTP.WS_CLOSE_STATUS_NO_STATUS == UInt16(1005)
    @test AwsHTTP.WS_CLOSE_STATUS_ABNORMAL == UInt16(1006)
end

# --- CLOSE payload encode/decode ---

@testset "WS close payload - encode/decode roundtrip" begin
    code = UInt16(1000)
    reason = Vector{UInt8}("Normal closure")
    payload = AwsHTTP.ws_encode_close_payload(code, reason)
    @test length(payload) == 2 + length(reason)

    decoded_code, decoded_reason = AwsHTTP.ws_decode_close_payload(payload)
    @test decoded_code == code
    @test decoded_reason == reason
end

@testset "WS close payload - no reason" begin
    payload = AwsHTTP.ws_encode_close_payload(UInt16(1001))
    @test length(payload) == 2
    code, reason = AwsHTTP.ws_decode_close_payload(payload)
    @test code == UInt16(1001)
    @test isempty(reason)
end

@testset "WS close payload - empty payload decode" begin
    code, reason = AwsHTTP.ws_decode_close_payload(UInt8[])
    @test code == UInt16(0)
    @test isempty(reason)
end

# --- 11.4: WebSocket handler ---

@testset "WS handshake - random key" begin
    key = AwsHTTP.ws_random_handshake_key()
    @test !isempty(key)
    # Base64-encoded 16 bytes = 24 chars
    @test length(key) == 24
    # Should be valid base64
    decoded = Base64.base64decode(key)
    @test length(decoded) == 16

    # Two keys should differ
    key2 = AwsHTTP.ws_random_handshake_key()
    @test key != key2
end

@testset "WS handshake - compute accept key (RFC 6455 known vector)" begin
    # RFC 6455 §4.2.2 example
    key = "dGhlIHNhbXBsZSBub25jZQ=="
    accept = AwsHTTP.ws_compute_accept_key(key)
    @test accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
end

@testset "WS handshake - new request" begin
    msg = AwsHTTP.ws_new_handshake_request("/chat", "example.com")
    @test AwsHTTP.http_message_is_request(msg)
    @test AwsHTTP.http_message_get_request_method(msg) == "GET"
    @test AwsHTTP.http_message_get_request_path(msg) == "/chat"

    hdrs = AwsHTTP.http_message_get_headers(msg)
    @test AwsHTTP.http_headers_get(hdrs, "Host") == "example.com"
    @test AwsHTTP.http_headers_get(hdrs, "Upgrade") == "websocket"
    @test AwsHTTP.http_headers_get(hdrs, "Connection") == "Upgrade"
    @test AwsHTTP.http_headers_get(hdrs, "Sec-WebSocket-Version") == "13"

    key = AwsHTTP.http_headers_get(hdrs, "Sec-WebSocket-Key")
    @test key !== nothing
    @test length(key) == 24
end

@testset "WS handshake - new response" begin
    key = "dGhlIHNhbXBsZSBub25jZQ=="
    msg = AwsHTTP.ws_new_handshake_response(key)
    @test !AwsHTTP.http_message_is_request(msg)
    @test AwsHTTP.http_message_get_response_status(msg) == 101

    hdrs = AwsHTTP.http_message_get_headers(msg)
    @test AwsHTTP.http_headers_get(hdrs, "Upgrade") == "websocket"
    @test AwsHTTP.http_headers_get(hdrs, "Connection") == "Upgrade"
    @test AwsHTTP.http_headers_get(hdrs, "Sec-WebSocket-Accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
end

@testset "WS handshake - is_websocket_request" begin
    msg = AwsHTTP.ws_new_handshake_request("/ws", "example.com")
    @test AwsHTTP.ws_is_websocket_request(msg) == true
end

@testset "WS handshake - is_websocket_request rejects non-upgrade" begin
    msg = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(msg, "GET")
    AwsHTTP.http_message_set_request_path(msg, "/api")
    @test AwsHTTP.ws_is_websocket_request(msg) == false
end

@testset "WS handshake - is_websocket_request rejects POST" begin
    msg = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(msg, "POST")
    AwsHTTP.http_message_set_request_path(msg, "/ws")
    hdrs = AwsHTTP.http_message_get_headers(msg)
    AwsHTTP.http_headers_add(hdrs, "Upgrade", "websocket")
    AwsHTTP.http_headers_add(hdrs, "Connection", "Upgrade")
    AwsHTTP.http_headers_add(hdrs, "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
    AwsHTTP.http_headers_add(hdrs, "Sec-WebSocket-Version", "13")
    @test AwsHTTP.ws_is_websocket_request(msg) == false
end

@testset "WS handshake - is_websocket_request rejects wrong version" begin
    msg = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(msg, "GET")
    AwsHTTP.http_message_set_request_path(msg, "/ws")
    hdrs = AwsHTTP.http_message_get_headers(msg)
    AwsHTTP.http_headers_add(hdrs, "Upgrade", "websocket")
    AwsHTTP.http_headers_add(hdrs, "Connection", "Upgrade")
    AwsHTTP.http_headers_add(hdrs, "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
    AwsHTTP.http_headers_add(hdrs, "Sec-WebSocket-Version", "8")
    @test AwsHTTP.ws_is_websocket_request(msg) == false
end

@testset "WS handshake - is_websocket_request rejects response" begin
    msg = AwsHTTP.http_message_new_response()
    @test AwsHTTP.ws_is_websocket_request(msg) == false
end

@testset "WS handshake - get_request_sec_websocket_key" begin
    msg = AwsHTTP.ws_new_handshake_request("/ws", "example.com")
    key = AwsHTTP.ws_get_request_sec_websocket_key(msg)
    @test key !== nothing
    @test length(key) == 24
end

@testset "WS handshake - get_request_sec_websocket_key missing" begin
    msg = AwsHTTP.http_message_new_request()
    key = AwsHTTP.ws_get_request_sec_websocket_key(msg)
    @test key === nothing
end

@testset "WS handshake - select_subprotocol" begin
    msg = AwsHTTP.ws_new_handshake_request("/ws", "example.com")
    hdrs = AwsHTTP.http_message_get_headers(msg)
    AwsHTTP.http_headers_add(hdrs, "Sec-WebSocket-Protocol", "chat, superchat, binary")

    # Server supports "superchat"
    result = AwsHTTP.ws_select_subprotocol(msg, ["superchat"])
    @test result == "superchat"
end

@testset "WS handshake - select_subprotocol no match" begin
    msg = AwsHTTP.ws_new_handshake_request("/ws", "example.com")
    hdrs = AwsHTTP.http_message_get_headers(msg)
    AwsHTTP.http_headers_add(hdrs, "Sec-WebSocket-Protocol", "chat, superchat")

    result = AwsHTTP.ws_select_subprotocol(msg, ["binary", "graphql"])
    @test result === nothing
end

@testset "WS handshake - select_subprotocol no header" begin
    msg = AwsHTTP.ws_new_handshake_request("/ws", "example.com")
    result = AwsHTTP.ws_select_subprotocol(msg, ["chat"])
    @test result === nothing
end

@testset "WS handshake - select_subprotocol case insensitive" begin
    msg = AwsHTTP.ws_new_handshake_request("/ws", "example.com")
    hdrs = AwsHTTP.http_message_get_headers(msg)
    AwsHTTP.http_headers_add(hdrs, "Sec-WebSocket-Protocol", "CHAT, Binary")

    result = AwsHTTP.ws_select_subprotocol(msg, ["chat"])
    @test result == "chat"
end

# --- Full handshake roundtrip ---

@testset "WS handshake - full client/server roundtrip" begin
    # Client creates request
    request = AwsHTTP.ws_new_handshake_request("/ws", "example.com")
    @test AwsHTTP.ws_is_websocket_request(request)

    # Server extracts key and creates response
    key = AwsHTTP.ws_get_request_sec_websocket_key(request)
    @test key !== nothing
    response = AwsHTTP.ws_new_handshake_response(key)

    # Client validates response
    @test AwsHTTP.http_message_get_response_status(response) == 101
    resp_hdrs = AwsHTTP.http_message_get_headers(response)
    accept = AwsHTTP.http_headers_get(resp_hdrs, "Sec-WebSocket-Accept")
    @test accept == AwsHTTP.ws_compute_accept_key(key)
end

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 12: Connection Manager
# ═══════════════════════════════════════════════════════════════════════════════

# Helper: mock connection for testing
mutable struct MockConnection
    is_open::Bool
    is_client::Bool
    closed::Bool
    user_data::Any
end

MockConnection() = MockConnection(true, true, false, nothing)

AwsHTTP.http_connection_is_open(c::MockConnection) = c.is_open
AwsHTTP.http_connection_is_client(c::MockConnection) = c.is_client
AwsHTTP.http_connection_close(c::MockConnection) = (c.closed = true; nothing)

function mock_factory(opts)
    return MockConnection()
end

connection_id_counter = Ref(0)
function mock_factory_with_id(opts)
    connection_id_counter[] += 1
    c = MockConnection()
    c.user_data = connection_id_counter[]
    return c
end

@testset "No-proxy matching - exact match" begin
    @test AwsHTTP.http_host_matches_no_proxy("localhost", "localhost") == true
    @test AwsHTTP.http_host_matches_no_proxy("example.com", "example.com") == true
end

@testset "No-proxy matching - domain suffix" begin
    @test AwsHTTP.http_host_matches_no_proxy("foo.example.com", "example.com") == true
    @test AwsHTTP.http_host_matches_no_proxy("bar.foo.example.com", "example.com") == true
    @test AwsHTTP.http_host_matches_no_proxy("example.com", "example.com") == true
    @test AwsHTTP.http_host_matches_no_proxy("notexample.com", "example.com") == false
end

@testset "No-proxy matching - leading dot" begin
    @test AwsHTTP.http_host_matches_no_proxy("foo.example.com", ".example.com") == true
    @test AwsHTTP.http_host_matches_no_proxy("example.com", ".example.com") == false
end

@testset "No-proxy matching - comma-separated list" begin
    no_proxy = "localhost, .internal.corp, example.com"
    @test AwsHTTP.http_host_matches_no_proxy("localhost", no_proxy) == true
    @test AwsHTTP.http_host_matches_no_proxy("foo.internal.corp", no_proxy) == true
    @test AwsHTTP.http_host_matches_no_proxy("example.com", no_proxy) == true
    @test AwsHTTP.http_host_matches_no_proxy("google.com", no_proxy) == false
end

@testset "No-proxy matching - wildcard" begin
    @test AwsHTTP.http_host_matches_no_proxy("anything.com", "*") == true
    @test AwsHTTP.http_host_matches_no_proxy("localhost", "*") == true
end

@testset "No-proxy matching - case insensitive" begin
    @test AwsHTTP.http_host_matches_no_proxy("EXAMPLE.COM", "example.com") == true
    @test AwsHTTP.http_host_matches_no_proxy("example.com", "EXAMPLE.COM") == true
end

@testset "No-proxy matching - IP address" begin
    @test AwsHTTP.http_host_matches_no_proxy("127.0.0.1", "127.0.0.1") == true
    @test AwsHTTP.http_host_matches_no_proxy("127.0.0.1", "127.0.0.2") == false
end

@testset "No-proxy matching - empty inputs" begin
    @test AwsHTTP.http_host_matches_no_proxy("example.com", "") == false
    @test AwsHTTP.http_host_matches_no_proxy("", "example.com") == false
    @test AwsHTTP.http_host_matches_no_proxy("", "") == false
end

@testset "No-proxy matching - whitespace handling" begin
    @test AwsHTTP.http_host_matches_no_proxy("example.com", " example.com ") == true
    @test AwsHTTP.http_host_matches_no_proxy(" example.com ", "example.com") == true
end

# --- 14.10: URI rewriting for forward proxy ---

@testset "HTTP1 statistics - init and reset" begin
    stats = AwsHTTP.crt_statistics_http1_channel_init()
    @test stats.pending_outgoing_stream_ms == 0
    @test stats.pending_incoming_stream_ms == 0
    @test stats.current_outgoing_stream_id == 0
    @test stats.current_incoming_stream_id == 0

    stats.pending_outgoing_stream_ms = UInt64(100)
    stats.pending_incoming_stream_ms = UInt64(200)
    AwsHTTP.crt_statistics_http1_channel_reset!(stats)
    @test stats.pending_outgoing_stream_ms == 0
    @test stats.pending_incoming_stream_ms == 0
    # Stream IDs preserved across reset
    @test stats.current_outgoing_stream_id == 0
end

# --- 15.2: HTTP/2 statistics ---

@testset "HTTP2 statistics - init and reset" begin
    stats = AwsHTTP.crt_statistics_http2_channel_init()
    @test stats.pending_outgoing_stream_ms == 0
    @test stats.pending_incoming_stream_ms == 0
    @test stats.was_inactive == false

    stats.pending_outgoing_stream_ms = UInt64(500)
    stats.was_inactive = true
    AwsHTTP.crt_statistics_http2_channel_reset!(stats)
    @test stats.pending_outgoing_stream_ms == 0
    @test stats.was_inactive == false
end

# --- 15.3: Connection monitor ---

@testset "Connection monitor - creation" begin
    mon = AwsHTTP.http_connection_monitor_new(
        options=AwsHTTP.HttpConnectionMonitoringOptions(UInt64(1000), UInt32(5)),
    )
    @test mon.health_state == AwsHTTP.ConnectionHealthState.HEALTHY
    @test mon.bytes_read == 0
    @test mon.bytes_written == 0
    @test mon.consecutive_failure_seconds == 0
end

@testset "Connection monitor - record bytes" begin
    mon = AwsHTTP.http_connection_monitor_new()
    AwsHTTP.http_connection_monitor_record_bytes!(mon, bytes_read=UInt64(100), bytes_written=UInt64(50))
    @test mon.bytes_read == 100
    @test mon.bytes_written == 50
    AwsHTTP.http_connection_monitor_record_bytes!(mon, bytes_read=UInt64(200))
    @test mon.bytes_read == 300
end

@testset "Connection monitor - healthy when no threshold" begin
    mon = AwsHTTP.http_connection_monitor_new(
        options=AwsHTTP.HttpConnectionMonitoringOptions(UInt64(0), UInt32(5)),
    )
    state = AwsHTTP.http_connection_monitor_check_throughput!(mon)
    @test state == AwsHTTP.ConnectionHealthState.HEALTHY
end

@testset "Connection monitor - healthy above threshold" begin
    mon = AwsHTTP.http_connection_monitor_new(
        options=AwsHTTP.HttpConnectionMonitoringOptions(UInt64(100), UInt32(5)),
    )
    # Record enough bytes
    AwsHTTP.http_connection_monitor_record_bytes!(mon, bytes_read=UInt64(500))
    # Simulate time passing
    mon.last_check_time_ns = time_ns() - UInt64(1_000_000_000)  # 1 second ago
    state = AwsHTTP.http_connection_monitor_check_throughput!(mon)
    @test state == AwsHTTP.ConnectionHealthState.HEALTHY
    @test mon.consecutive_failure_seconds == 0
end

@testset "Connection monitor - degraded below threshold" begin
    mon = AwsHTTP.http_connection_monitor_new(
        options=AwsHTTP.HttpConnectionMonitoringOptions(UInt64(1000), UInt32(5)),
    )
    # Record very few bytes
    AwsHTTP.http_connection_monitor_record_bytes!(mon, bytes_read=UInt64(1))
    mon.last_check_time_ns = time_ns() - UInt64(1_000_000_000)
    state = AwsHTTP.http_connection_monitor_check_throughput!(mon)
    @test state == AwsHTTP.ConnectionHealthState.DEGRADED
    @test mon.consecutive_failure_seconds >= 1
end

@testset "Connection monitor - recovers when throughput restored" begin
    mon = AwsHTTP.http_connection_monitor_new(
        options=AwsHTTP.HttpConnectionMonitoringOptions(UInt64(100), UInt32(5)),
    )

    # Go degraded
    AwsHTTP.http_connection_monitor_record_bytes!(mon, bytes_read=UInt64(1))
    mon.last_check_time_ns = time_ns() - UInt64(1_000_000_000)
    AwsHTTP.http_connection_monitor_check_throughput!(mon)
    @test mon.health_state == AwsHTTP.ConnectionHealthState.DEGRADED

    # Recover
    AwsHTTP.http_connection_monitor_record_bytes!(mon, bytes_read=UInt64(500))
    mon.last_check_time_ns = time_ns() - UInt64(1_000_000_000)
    state = AwsHTTP.http_connection_monitor_check_throughput!(mon)
    @test state == AwsHTTP.ConnectionHealthState.HEALTHY
    @test mon.consecutive_failure_seconds == 0
end

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 16: Utility modules
# ═══════════════════════════════════════════════════════════════════════════════

# --- 16.1: String utilities ---

@testset "strutil - is_http_token" begin
    @test AwsHTTP.strutil_is_http_token("Content-Type") == true
    @test AwsHTTP.strutil_is_http_token("Accept") == true
    @test AwsHTTP.strutil_is_http_token("X-Custom-Header") == true
    @test AwsHTTP.strutil_is_http_token("Host") == true
    @test AwsHTTP.strutil_is_http_token("GET") == true
    @test AwsHTTP.strutil_is_http_token("") == false
    @test AwsHTTP.strutil_is_http_token("Content Type") == false  # space
    @test AwsHTTP.strutil_is_http_token("Header:Name") == false  # colon
    @test AwsHTTP.strutil_is_http_token("Header\tName") == false  # tab
end

@testset "strutil - is_http_field_value" begin
    @test AwsHTTP.strutil_is_http_field_value("text/html") == true
    @test AwsHTTP.strutil_is_http_field_value("Bearer abc123") == true
    @test AwsHTTP.strutil_is_http_field_value("") == true  # empty is valid
    @test AwsHTTP.strutil_is_http_field_value("value with\ttab") == true  # HTAB allowed
    @test AwsHTTP.strutil_is_http_field_value("value\x00null") == false  # NUL not allowed
    @test AwsHTTP.strutil_is_http_field_value("line\nbreak") == false  # LF not allowed
end

@testset "strutil - is_http_request_target" begin
    @test AwsHTTP.strutil_is_http_request_target("/api/data") == true
    @test AwsHTTP.strutil_is_http_request_target("/") == true
    @test AwsHTTP.strutil_is_http_request_target("*") == true
    @test AwsHTTP.strutil_is_http_request_target("http://example.com/api") == true
    @test AwsHTTP.strutil_is_http_request_target("") == false
    @test AwsHTTP.strutil_is_http_request_target("/path with space") == false
end

@testset "strutil - is_http_pseudo_header_name" begin
    @test AwsHTTP.strutil_is_http_pseudo_header_name(":method") == true
    @test AwsHTTP.strutil_is_http_pseudo_header_name(":path") == true
    @test AwsHTTP.strutil_is_http_pseudo_header_name(":status") == true
    @test AwsHTTP.strutil_is_http_pseudo_header_name("Content-Type") == false
    @test AwsHTTP.strutil_is_http_pseudo_header_name("") == false
end

@testset "strutil - trim_http_whitespace" begin
    @test AwsHTTP.strutil_trim_http_whitespace("  hello  ") == "hello"
    @test AwsHTTP.strutil_trim_http_whitespace("\thello\t") == "hello"
    @test AwsHTTP.strutil_trim_http_whitespace("  \t hello \t  ") == "hello"
    @test AwsHTTP.strutil_trim_http_whitespace("hello") == "hello"
    @test AwsHTTP.strutil_trim_http_whitespace("") == ""
    @test AwsHTTP.strutil_trim_http_whitespace("   ") == ""
end

@testset "strutil - is_uppercase_http_method" begin
    @test AwsHTTP.strutil_is_uppercase_http_method("GET") == true
    @test AwsHTTP.strutil_is_uppercase_http_method("POST") == true
    @test AwsHTTP.strutil_is_uppercase_http_method("DELETE") == true
    @test AwsHTTP.strutil_is_uppercase_http_method("get") == false
    @test AwsHTTP.strutil_is_uppercase_http_method("Get") == false
    @test AwsHTTP.strutil_is_uppercase_http_method("") == false
end

@testset "strutil - is_lowercase_http_header_name" begin
    @test AwsHTTP.strutil_is_lowercase_http_header_name("content-type") == true
    @test AwsHTTP.strutil_is_lowercase_http_header_name(":method") == true
    @test AwsHTTP.strutil_is_lowercase_http_header_name(":status") == true
    @test AwsHTTP.strutil_is_lowercase_http_header_name("Content-Type") == false
    @test AwsHTTP.strutil_is_lowercase_http_header_name("") == false
end

# --- 16.2: Random access set ---

@testset "Random access set - basic operations" begin
    set = AwsHTTP.RandomAccessSet{Int}()
    @test AwsHTTP.random_access_set_size(set) == 0

    @test AwsHTTP.random_access_set_add!(set, 1) == true
    @test AwsHTTP.random_access_set_add!(set, 2) == true
    @test AwsHTTP.random_access_set_add!(set, 3) == true
    @test AwsHTTP.random_access_set_size(set) == 3

    # Duplicate add returns false
    @test AwsHTTP.random_access_set_add!(set, 2) == false
    @test AwsHTTP.random_access_set_size(set) == 3
end

@testset "Random access set - contains" begin
    set = AwsHTTP.RandomAccessSet{String}()
    AwsHTTP.random_access_set_add!(set, "a")
    AwsHTTP.random_access_set_add!(set, "b")
    @test AwsHTTP.random_access_set_contains(set, "a") == true
    @test AwsHTTP.random_access_set_contains(set, "b") == true
    @test AwsHTTP.random_access_set_contains(set, "c") == false
end

@testset "Random access set - remove" begin
    set = AwsHTTP.RandomAccessSet{Int}()
    AwsHTTP.random_access_set_add!(set, 10)
    AwsHTTP.random_access_set_add!(set, 20)
    AwsHTTP.random_access_set_add!(set, 30)

    @test AwsHTTP.random_access_set_remove!(set, 20) == true
    @test AwsHTTP.random_access_set_size(set) == 2
    @test AwsHTTP.random_access_set_contains(set, 20) == false
    @test AwsHTTP.random_access_set_contains(set, 10) == true
    @test AwsHTTP.random_access_set_contains(set, 30) == true

    # Remove non-existent
    @test AwsHTTP.random_access_set_remove!(set, 99) == false
end

@testset "Random access set - random access" begin
    set = AwsHTTP.RandomAccessSet{Int}()
    @test AwsHTTP.random_access_set_random(set) === nothing

    AwsHTTP.random_access_set_add!(set, 42)
    @test AwsHTTP.random_access_set_random(set) == 42

    AwsHTTP.random_access_set_add!(set, 43)
    AwsHTTP.random_access_set_add!(set, 44)
    # Random should return one of the elements
    r = AwsHTTP.random_access_set_random(set)
    @test r ∈ [42, 43, 44]
end

@testset "Random access set - clean up" begin
    set = AwsHTTP.RandomAccessSet{Int}()
    AwsHTTP.random_access_set_add!(set, 1)
    AwsHTTP.random_access_set_add!(set, 2)
    AwsHTTP.random_access_set_clean_up!(set)
    @test AwsHTTP.random_access_set_size(set) == 0
end

@testset "Random access set - remove maintains integrity" begin
    set = AwsHTTP.RandomAccessSet{Int}()
    for i in 1:10
        AwsHTTP.random_access_set_add!(set, i)
    end

    # Remove middle elements
    AwsHTTP.random_access_set_remove!(set, 5)
    AwsHTTP.random_access_set_remove!(set, 3)
    AwsHTTP.random_access_set_remove!(set, 8)
    @test AwsHTTP.random_access_set_size(set) == 7

    # All remaining elements should be accessible
    for i in [1, 2, 4, 6, 7, 9, 10]
        @test AwsHTTP.random_access_set_contains(set, i) == true
    end
    for i in [3, 5, 8]
        @test AwsHTTP.random_access_set_contains(set, i) == false
    end
end

# ─── Phase 17: Integration tests ─── HTTP/1.1 client-server round-trips ───

# Helper: build an H1 request message
function make_h1_request(method, path, headers=Pair{String,String}[]; body=nothing)
    msg = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(msg, method)
    AwsHTTP.http_message_set_request_path(msg, path)
    for (k, v) in headers
        AwsHTTP.http_headers_add(AwsHTTP.http_message_get_headers(msg), k, v)
    end
    if body !== nothing
        AwsHTTP.http_message_set_body_stream(msg, IOBuffer(Vector{UInt8}(body)))
    end
    return msg
end

# Helper: build an H1 response message
function make_h1_response(status, headers=Pair{String,String}[]; body=nothing)
    msg = AwsHTTP.http_message_new_response()
    AwsHTTP.http_message_set_response_status(msg, status)
    for (k, v) in headers
        AwsHTTP.http_headers_add(AwsHTTP.http_message_get_headers(msg), k, v)
    end
    if body !== nothing
        AwsHTTP.http_message_set_body_stream(msg, IOBuffer(Vector{UInt8}(body)))
    end
    return msg
end

# Helper: do a full H1 client-server round-trip
# Returns (response_status, response_headers, response_body, server_method, server_path, server_headers, server_body)
function h1_round_trip(request_msg, response_msg)
    # === Client side ===
    client_status = Ref{Int}(-1)
    client_headers = HttpHeader[]
    client_body = UInt8[]
    client_complete_error = Ref{Int}(-999)

    client_conn = AwsHTTP.h1_connection_new_client()
    stream = AwsHTTP.http_connection_make_request(client_conn, AwsHTTP.HttpMakeRequestOptions(
        request=request_msg,
        on_response_headers=(s, block, hdrs, ud) -> begin
            append!(client_headers, hdrs)
            return Reseau.OP_SUCCESS
        end,
        on_response_body=(s, data, ud) -> begin
            append!(client_body, data)
            return Reseau.OP_SUCCESS
        end,
        on_complete=(s, ec, ud) -> begin
            client_complete_error[] = ec
            client_status[] = AwsHTTP.http_stream_get_incoming_response_status(s)
            nothing
        end,
    ))
    @test stream !== nothing
    @test AwsHTTP.h1_stream_activate!(stream) == Reseau.OP_SUCCESS

    # Encode client request bytes (may need multiple passes for large bodies)
    request_bytes = UInt8[]
    while true
        status, chunk = AwsHTTP.h1_connection_encode_outgoing!(client_conn)
        @test status == Reseau.OP_SUCCESS
        isempty(chunk) && break
        append!(request_bytes, chunk)
    end
    @test !isempty(request_bytes)

    # === Server side ===
    server_method = Ref{String}("")
    server_path = Ref{String}("")
    server_headers = HttpHeader[]
    server_body = UInt8[]
    server_request_done = Ref{Bool}(false)

    server_conn = AwsHTTP.h1_connection_new_server()

    server_stream = AwsHTTP.h1_stream_new_request_handler(AwsHTTP.HttpRequestHandlerOptions(
        server_conn,          # server_connection
        nothing,              # user_data
        (s, block, hdrs, ud) -> begin  # on_request_headers
            append!(server_headers, hdrs)
            return Reseau.OP_SUCCESS
        end,
        nothing,              # on_request_header_block_done
        (s, data, ud) -> begin  # on_request_body
            append!(server_body, data)
            return Reseau.OP_SUCCESS
        end,
        (s, ud) -> begin      # on_request_done
            server_method[] = AwsHTTP.http_stream_get_incoming_request_method(s)
            server_path[] = AwsHTTP.http_stream_get_incoming_request_uri(s)
            server_request_done[] = true
            nothing
        end,
        nothing,              # on_complete
        nothing,              # on_destroy
    ))
    @test AwsHTTP.h1_stream_activate!(server_stream) == Reseau.OP_SUCCESS

    # Feed request bytes to server decoder
    @test AwsHTTP.h1_connection_process_read_data!(server_conn, request_bytes) == Reseau.OP_SUCCESS
    @test server_request_done[]

    # Server sends response (may need multiple passes for large bodies)
    enc_msg = AwsHTTP.H1EncoderMessage()
    @test AwsHTTP.h1_encoder_message_init_from_response!(enc_msg, response_msg) == Reseau.OP_SUCCESS
    server_stream.encoder_message = enc_msg
    response_bytes = UInt8[]
    while true
        status2, chunk = AwsHTTP.h1_connection_encode_outgoing!(server_conn)
        @test status2 == Reseau.OP_SUCCESS
        isempty(chunk) && break
        append!(response_bytes, chunk)
    end
    @test !isempty(response_bytes)

    # Feed response bytes to client decoder
    @test AwsHTTP.h1_connection_process_read_data!(client_conn, response_bytes) == Reseau.OP_SUCCESS

    # Cleanup
    AwsHTTP.h1_connection_destroy!(client_conn)
    AwsHTTP.h1_connection_destroy!(server_conn)

    return (
        client_status[],
        client_headers,
        client_body,
        server_method[],
        server_path[],
        server_headers,
        server_body,
        client_complete_error[],
    )
end

using AwsHTTP: HttpHeader

@testset "H1 integration - simple GET round-trip" begin
    req = make_h1_request("GET", "/index.html", ["Host" => "example.com"])
    resp = make_h1_response(200, ["Content-Length" => "2"]; body="OK")

    status, rhdrs, rbody, smethod, spath, shdrs, sbody, cerr = h1_round_trip(req, resp)

    @test status == 200
    @test cerr == 0
    @test smethod == "GET"
    @test spath == "/index.html"
    @test any(h -> h.name == "Host" && h.value == "example.com", shdrs)
    @test String(rbody) == "OK"
end

@testset "H1 integration - POST with body round-trip" begin
    body_data = "name=test&value=123"
    req = make_h1_request("POST", "/api/data",
        ["Host" => "example.com", "Content-Type" => "application/x-www-form-urlencoded",
         "Content-Length" => string(length(body_data))];
        body=body_data)
    resp_body = "{\"status\":\"ok\"}"
    resp = make_h1_response(200, ["Content-Type" => "application/json",
        "Content-Length" => string(length(resp_body))]; body=resp_body)

    status, rhdrs, rbody, smethod, spath, shdrs, sbody, cerr = h1_round_trip(req, resp)

    @test status == 200
    @test cerr == 0
    @test smethod == "POST"
    @test spath == "/api/data"
    @test String(sbody) == body_data
    @test String(rbody) == resp_body
end

@testset "H1 integration - 404 response" begin
    req = make_h1_request("GET", "/missing", ["Host" => "example.com"])
    resp = make_h1_response(404, ["Content-Length" => "9"]; body="Not Found")

    status, _, rbody, _, spath, _, _, cerr = h1_round_trip(req, resp)

    @test status == 404
    @test cerr == 0
    @test spath == "/missing"
    @test String(rbody) == "Not Found"
end

@testset "H1 integration - HEAD request (no body)" begin
    req = make_h1_request("HEAD", "/check", ["Host" => "example.com"])
    # HEAD response: no body, Content-Length: 0
    # Note: a real HTTP server would send Content-Length matching the GET body size,
    # but the H1 decoder in-memory cannot know the request method, so we use 0.
    resp = make_h1_response(200, ["Content-Length" => "0"])

    status, _, rbody, smethod, _, _, _, cerr = h1_round_trip(req, resp)

    @test status == 200
    @test cerr == 0
    @test smethod == "HEAD"
    @test isempty(rbody)
end

@testset "H1 integration - multiple headers" begin
    req = make_h1_request("GET", "/", [
        "Host" => "example.com",
        "Accept" => "text/html",
        "Accept-Language" => "en-US",
        "User-Agent" => "AwsHTTP/1.0",
        "X-Custom" => "test-value",
    ])
    resp = make_h1_response(200, [
        "Content-Type" => "text/html",
        "X-Request-Id" => "abc123",
        "Cache-Control" => "no-cache",
        "Content-Length" => "5",
    ]; body="hello")

    status, rhdrs, rbody, _, _, shdrs, _, cerr = h1_round_trip(req, resp)

    @test status == 200
    @test cerr == 0
    @test length(shdrs) >= 5  # all request headers received
    @test any(h -> h.name == "X-Custom" && h.value == "test-value", shdrs)
    @test any(h -> h.name == "X-Request-Id" && h.value == "abc123", rhdrs)
    @test String(rbody) == "hello"
end

@testset "H1 integration - large body" begin
    # 64 KB body
    large_body = repeat("A", 65536)
    req = make_h1_request("PUT", "/upload",
        ["Host" => "example.com", "Content-Length" => string(length(large_body))];
        body=large_body)
    resp = make_h1_response(201, ["Content-Length" => "7"]; body="created")

    status, _, rbody, smethod, _, _, sbody, cerr = h1_round_trip(req, resp)

    @test status == 201
    @test cerr == 0
    @test smethod == "PUT"
    @test length(sbody) == 65536
    @test all(==(UInt8('A')), sbody)
    @test String(rbody) == "created"
end

@testset "H1 integration - empty body response" begin
    req = make_h1_request("DELETE", "/resource/42", ["Host" => "example.com"])
    resp = make_h1_response(204, ["Content-Length" => "0"])

    status, _, rbody, smethod, spath, _, _, cerr = h1_round_trip(req, resp)

    @test status == 204
    @test cerr == 0
    @test smethod == "DELETE"
    @test spath == "/resource/42"
    @test isempty(rbody)
end

@testset "H1 integration - connection close" begin
    req = make_h1_request("GET", "/", ["Host" => "example.com"])
    resp = make_h1_response(200, ["Connection" => "close", "Content-Length" => "4"]; body="done")

    status, rhdrs, rbody, _, _, _, _, cerr = h1_round_trip(req, resp)

    @test status == 200
    @test cerr == 0
    @test String(rbody) == "done"
end

# ─── Phase 17: HTTP/2 integration tests ───

@testset "H2 integration - preface exchange" begin
    client = AwsHTTP.h2_connection_new(is_client=true)
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Client preface
    status_c, client_preface = AwsHTTP.h2_connection_get_preface(client)
    @test status_c == Reseau.OP_SUCCESS
    @test !isempty(client_preface)

    # Server preface
    status_s, server_preface = AwsHTTP.h2_connection_get_preface(server)
    @test status_s == Reseau.OP_SUCCESS
    @test !isempty(server_preface)

    # Server decodes client preface (magic + SETTINGS)
    err, frames = AwsHTTP.h2_connection_decode!(server, client_preface)
    @test !AwsHTTP.h2err_failed(err)

    # Client decodes server preface (SETTINGS)
    err2, frames2 = AwsHTTP.h2_connection_decode!(client, server_preface)
    @test !AwsHTTP.h2err_failed(err2)

    # Both should have queued SETTINGS ACK
    server_ack = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    @test !isempty(server_ack)

    client_ack = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    @test !isempty(client_ack)

    # Process ACKs
    err3, _ = AwsHTTP.h2_connection_decode!(server, client_ack)
    @test !AwsHTTP.h2err_failed(err3)

    err4, _ = AwsHTTP.h2_connection_decode!(client, server_ack)
    @test !AwsHTTP.h2err_failed(err4)
end

@testset "H2 integration - simple request-response (no body)" begin
    client = AwsHTTP.h2_connection_new(is_client=true)
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Exchange prefaces
    _, cp = AwsHTTP.h2_connection_get_preface(client)
    _, sp = AwsHTTP.h2_connection_get_preface(server)
    AwsHTTP.h2_connection_decode!(server, cp)
    AwsHTTP.h2_connection_decode!(client, sp)
    sa = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    ca = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    AwsHTTP.h2_connection_decode!(server, ca)
    AwsHTTP.h2_connection_decode!(client, sa)

    # Client creates request
    resp_status = Ref{Int}(-1)
    resp_headers = HttpHeader[]
    complete_error = Ref{Int}(-999)

    req = AwsHTTP.http2_message_new_request()
    AwsHTTP.http_headers_add(AwsHTTP.http_message_get_headers(req), ":method", "GET")
    AwsHTTP.http_headers_add(AwsHTTP.http_message_get_headers(req), ":scheme", "https")
    AwsHTTP.http_headers_add(AwsHTTP.http_message_get_headers(req), ":path", "/")
    AwsHTTP.http_headers_add(AwsHTTP.http_message_get_headers(req), ":authority", "example.com")

    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(
        request=req,
        on_response_headers=(s, block, hdrs, ud) -> begin
            append!(resp_headers, hdrs)
            return 0
        end,
        on_complete=(s, ec, ud) -> begin
            complete_error[] = ec
            resp_status[] = AwsHTTP.h2_stream_get_incoming_response_status(s)
            nothing
        end,
    ))
    @test stream !== nothing

    # Activate stream (sends HEADERS with END_STREAM)
    status, body_state = AwsHTTP.h2_stream_activate!(stream, client)
    @test status == Reseau.OP_SUCCESS

    # Get stream frames and connection frames
    stream_frames = AwsHTTP.h2_stream_get_outgoing_frames!(stream)
    conn_frames = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    request_bytes = vcat(conn_frames, stream_frames)

    # Server decodes request
    err, decoded_frames = AwsHTTP.h2_connection_decode!(server, request_bytes)
    @test !AwsHTTP.h2err_failed(err)
    @test !isempty(decoded_frames)

    # Find HEADERS frame
    headers_frame = decoded_frames[1]
    @test headers_frame.frame_type == AwsHTTP.H2FrameType.HEADERS
    @test headers_frame.stream_id == UInt32(1)  # first client stream

    # Server sends response (200 OK, no body, END_STREAM)
    resp = AwsHTTP.http2_message_new_response()
    AwsHTTP.http2_headers_set_response_status(AwsHTTP.http_message_get_headers(resp), 200)
    AwsHTTP.http_headers_add(AwsHTTP.http_message_get_headers(resp), "content-type", "text/plain")

    server_stream = AwsHTTP.h2_stream_new_request_handler(server, AwsHTTP.HttpRequestHandlerOptions(
        server, nothing, nothing, nothing, nothing, nothing, nothing, nothing))
    server_stream.id = UInt32(1)
    server_stream.state = AwsHTTP.H2StreamState.OPEN
    server_stream.received_main_headers = true
    server.active_streams[UInt32(1)] = server_stream
    AwsHTTP.h2_stream_init_window_sizes!(server_stream, server)

    @test AwsHTTP.h2_stream_send_response!(server_stream, server, resp) == Reseau.OP_SUCCESS

    response_bytes = AwsHTTP.h2_stream_get_outgoing_frames!(server_stream)

    # Client decodes response
    err2, resp_frames = AwsHTTP.h2_connection_decode!(client, response_bytes)
    @test !AwsHTTP.h2err_failed(err2)
    @test !isempty(resp_frames)

    # Dispatch to stream
    for f in resp_frames
        if f.frame_type == AwsHTTP.H2FrameType.HEADERS && f.stream_id == stream.id
            AwsHTTP.h2_stream_on_headers!(stream, f.headers, AwsHTTP.HttpHeaderBlock.MAIN, f.end_stream)
            AwsHTTP.h2_stream_on_headers_end!(stream, AwsHTTP.HttpHeaderBlock.MAIN, f.end_stream)
        end
    end

    @test stream.response_status == 200
    @test !isempty(resp_headers)
    @test any(h -> h.name == "content-type" && h.value == "text/plain", resp_headers)
end

@testset "H2 integration - request with body" begin
    client = AwsHTTP.h2_connection_new(is_client=true)
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Exchange prefaces
    _, cp = AwsHTTP.h2_connection_get_preface(client)
    _, sp = AwsHTTP.h2_connection_get_preface(server)
    AwsHTTP.h2_connection_decode!(server, cp)
    AwsHTTP.h2_connection_decode!(client, sp)
    sa = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    ca = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    AwsHTTP.h2_connection_decode!(server, ca)
    AwsHTTP.h2_connection_decode!(client, sa)

    # Client creates POST request with body
    body_content = Vector{UInt8}("Hello, HTTP/2!")

    req = AwsHTTP.http2_message_new_request()
    hdrs = AwsHTTP.http_message_get_headers(req)
    AwsHTTP.http_headers_add(hdrs, ":method", "POST")
    AwsHTTP.http_headers_add(hdrs, ":scheme", "https")
    AwsHTTP.http_headers_add(hdrs, ":path", "/upload")
    AwsHTTP.http_headers_add(hdrs, ":authority", "example.com")
    AwsHTTP.http_headers_add(hdrs, "content-length", string(length(body_content)))
    AwsHTTP.http_message_set_body_stream(req, body_content)

    resp_body = UInt8[]

    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(
        request=req,
        on_response_body=(s, data, ud) -> begin
            append!(resp_body, data)
            return 0
        end,
    ))

    status, body_state = AwsHTTP.h2_stream_activate!(stream, client)
    @test status == Reseau.OP_SUCCESS
    @test body_state == AwsHTTP.H2StreamBodyState.ONGOING

    # Get HEADERS frame
    headers_bytes = AwsHTTP.h2_stream_get_outgoing_frames!(stream)
    @test !isempty(headers_bytes)

    # Encode DATA frame
    enc_status, enc_state = AwsHTTP.h2_stream_encode_data_frame!(stream, client)
    @test enc_status == Reseau.OP_SUCCESS

    data_bytes = AwsHTTP.h2_stream_get_outgoing_frames!(stream)
    @test !isempty(data_bytes)

    # Server decodes HEADERS + DATA
    all_bytes = vcat(headers_bytes, data_bytes)
    err, frames = AwsHTTP.h2_connection_decode!(server, all_bytes)
    @test !AwsHTTP.h2err_failed(err)
    @test length(frames) >= 2  # HEADERS + DATA

    # Verify HEADERS frame
    h_frame = frames[1]
    @test h_frame.frame_type == AwsHTTP.H2FrameType.HEADERS
    @test !h_frame.end_stream  # has body, so END_STREAM not on HEADERS

    # Verify DATA frame
    d_frame = frames[2]
    @test d_frame.frame_type == AwsHTTP.H2FrameType.DATA
    @test d_frame.end_stream  # END_STREAM on final DATA
    @test d_frame.data == body_content
end

@testset "H2 integration - PING round-trip" begin
    client = AwsHTTP.h2_connection_new(is_client=true)
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Exchange prefaces
    _, cp = AwsHTTP.h2_connection_get_preface(client)
    _, sp = AwsHTTP.h2_connection_get_preface(server)
    AwsHTTP.h2_connection_decode!(server, cp)
    AwsHTTP.h2_connection_decode!(client, sp)
    sa = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    ca = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    AwsHTTP.h2_connection_decode!(server, ca)
    AwsHTTP.h2_connection_decode!(client, sa)

    # Client sends PING
    ping_data = UInt8[1, 2, 3, 4, 5, 6, 7, 8]
    ping_future = AwsHTTP.h2_connection_send_ping!(client, ping_data)

    ping_bytes = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    @test !isempty(ping_bytes)

    # Server receives PING, auto-sends PING ACK
    err, _ = AwsHTTP.h2_connection_decode!(server, ping_bytes)
    @test !AwsHTTP.h2err_failed(err)

    ack_bytes = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    @test !isempty(ack_bytes)

    # Client receives PING ACK
    err2, _ = AwsHTTP.h2_connection_decode!(client, ack_bytes)
    @test !AwsHTTP.h2err_failed(err2)

    rtt, ping_status = wait(ping_future)
    @test ping_status == Reseau.OP_SUCCESS
    @test rtt > 0
end

@testset "H2 integration - GOAWAY exchange" begin
    client = AwsHTTP.h2_connection_new(is_client=true)
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Exchange prefaces
    _, cp = AwsHTTP.h2_connection_get_preface(client)
    _, sp = AwsHTTP.h2_connection_get_preface(server)
    AwsHTTP.h2_connection_decode!(server, cp)
    AwsHTTP.h2_connection_decode!(client, sp)
    sa = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    ca = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    AwsHTTP.h2_connection_decode!(server, ca)
    AwsHTTP.h2_connection_decode!(client, sa)

    # Server sends GOAWAY
    goaway_received = Ref{Bool}(false)
    goaway_last_stream = Ref{UInt32}(0)
    goaway_error = Ref{UInt32}(0)

    client.on_goaway_received = (last_id, ec, debug) -> begin
        goaway_received[] = true
        goaway_last_stream[] = last_id
        goaway_error[] = ec
        nothing
    end

    @test AwsHTTP.h2_connection_send_goaway!(server;
        error_code=UInt32(0),
        debug_data=Vector{UInt8}("shutting down")) == Reseau.OP_SUCCESS

    goaway_bytes = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    @test !isempty(goaway_bytes)

    # Client receives GOAWAY
    err, _ = AwsHTTP.h2_connection_decode!(client, goaway_bytes)
    @test !AwsHTTP.h2err_failed(err)

    @test goaway_received[]
    @test goaway_error[] == 0
    @test !AwsHTTP.http_connection_new_requests_allowed(client)
end

@testset "H2 integration - settings change" begin
    client = AwsHTTP.h2_connection_new(is_client=true)
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Exchange prefaces
    _, cp = AwsHTTP.h2_connection_get_preface(client)
    _, sp = AwsHTTP.h2_connection_get_preface(server)
    AwsHTTP.h2_connection_decode!(server, cp)
    AwsHTTP.h2_connection_decode!(client, sp)
    sa = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    ca = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    AwsHTTP.h2_connection_decode!(server, ca)
    AwsHTTP.h2_connection_decode!(client, sa)

    # Client changes max concurrent streams setting
    new_max = UInt32(64)
    settings = [AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.MAX_CONCURRENT_STREAMS, new_max)]

    settings_future = AwsHTTP.h2_connection_change_settings!(client, settings)

    settings_bytes = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    @test !isempty(settings_bytes)

    # Server receives SETTINGS, auto-sends ACK
    remote_settings_changed = Ref{Bool}(false)
    server.on_remote_settings_change = (changed) -> begin
        remote_settings_changed[] = true
        nothing
    end

    err, _ = AwsHTTP.h2_connection_decode!(server, settings_bytes)
    @test !AwsHTTP.h2err_failed(err)
    @test remote_settings_changed[]
    @test server.settings_remote[AwsHTTP.Http2SettingsId.MAX_CONCURRENT_STREAMS] == new_max

    # Client receives SETTINGS ACK
    ack_bytes = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    err2, _ = AwsHTTP.h2_connection_decode!(client, ack_bytes)
    @test !AwsHTTP.h2err_failed(err2)
    @test wait(settings_future) == Reseau.OP_SUCCESS
    @test client.settings_local[AwsHTTP.Http2SettingsId.MAX_CONCURRENT_STREAMS] == new_max
end

@testset "H2 integration - RST_STREAM" begin
    client = AwsHTTP.h2_connection_new(is_client=true)
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Exchange prefaces
    _, cp = AwsHTTP.h2_connection_get_preface(client)
    _, sp = AwsHTTP.h2_connection_get_preface(server)
    AwsHTTP.h2_connection_decode!(server, cp)
    AwsHTTP.h2_connection_decode!(client, sp)
    sa = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    ca = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    AwsHTTP.h2_connection_decode!(server, ca)
    AwsHTTP.h2_connection_decode!(client, sa)

    # Client creates request stream
    req = AwsHTTP.http2_message_new_request()
    hdrs = AwsHTTP.http_message_get_headers(req)
    AwsHTTP.http_headers_add(hdrs, ":method", "GET")
    AwsHTTP.http_headers_add(hdrs, ":scheme", "https")
    AwsHTTP.http_headers_add(hdrs, ":path", "/slow")
    AwsHTTP.http_headers_add(hdrs, ":authority", "example.com")

    stream = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=req))
    status, _ = AwsHTTP.h2_stream_activate!(stream, client)
    @test status == Reseau.OP_SUCCESS
    @test stream.state == AwsHTTP.H2StreamState.HALF_CLOSED_LOCAL

    # Client cancels the stream
    @test AwsHTTP.h2_stream_cancel!(stream) == Reseau.OP_SUCCESS
    @test stream.state == AwsHTTP.H2StreamState.CLOSED

    rst_bytes = AwsHTTP.h2_stream_get_outgoing_frames!(stream)
    @test !isempty(rst_bytes)

    # Send HEADERS + RST to server
    all_bytes = vcat(AwsHTTP.h2_stream_get_outgoing_frames!(stream), rst_bytes)
    err, frames = AwsHTTP.h2_connection_decode!(server, all_bytes)
    @test !AwsHTTP.h2err_failed(err)
end

@testset "H2 integration - connection-level WINDOW_UPDATE" begin
    client = AwsHTTP.h2_connection_new(is_client=true, manual_window_management=true,
        initial_window_size=UInt32(65535))
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Exchange prefaces
    _, cp = AwsHTTP.h2_connection_get_preface(client)
    _, sp = AwsHTTP.h2_connection_get_preface(server)
    AwsHTTP.h2_connection_decode!(server, cp)
    AwsHTTP.h2_connection_decode!(client, sp)
    sa = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    ca = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    AwsHTTP.h2_connection_decode!(server, ca)
    AwsHTTP.h2_connection_decode!(client, sa)

    old_window = server.window_size_peer

    # Client sends WINDOW_UPDATE to increase its receive window
    @test AwsHTTP.h2_connection_update_window!(client, UInt32(32768)) == Reseau.OP_SUCCESS
    wu_bytes = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    @test !isempty(wu_bytes)

    # Server processes WINDOW_UPDATE
    err, _ = AwsHTTP.h2_connection_decode!(server, wu_bytes)
    @test !AwsHTTP.h2err_failed(err)
    @test server.window_size_peer == old_window + 32768
end

@testset "H2 integration - multiple concurrent streams" begin
    client = AwsHTTP.h2_connection_new(is_client=true)
    server = AwsHTTP.h2_connection_new(is_client=false)

    # Exchange prefaces
    _, cp = AwsHTTP.h2_connection_get_preface(client)
    _, sp = AwsHTTP.h2_connection_get_preface(server)
    AwsHTTP.h2_connection_decode!(server, cp)
    AwsHTTP.h2_connection_decode!(client, sp)
    sa = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    ca = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    AwsHTTP.h2_connection_decode!(server, ca)
    AwsHTTP.h2_connection_decode!(client, sa)

    # Create 3 concurrent streams
    streams = AwsHTTP.H2Stream[]
    for i in 1:3
        req = AwsHTTP.http2_message_new_request()
        h = AwsHTTP.http_message_get_headers(req)
        AwsHTTP.http_headers_add(h, ":method", "GET")
        AwsHTTP.http_headers_add(h, ":scheme", "https")
        AwsHTTP.http_headers_add(h, ":path", "/stream$i")
        AwsHTTP.http_headers_add(h, ":authority", "example.com")

        s = AwsHTTP.h2_stream_new_request(client, AwsHTTP.HttpMakeRequestOptions(request=req))
        @test s !== nothing
        status, _ = AwsHTTP.h2_stream_activate!(s, client)
        @test status == Reseau.OP_SUCCESS
        push!(streams, s)
    end

    # Verify all streams got unique, odd IDs
    @test streams[1].id == UInt32(1)
    @test streams[2].id == UInt32(3)
    @test streams[3].id == UInt32(5)

    # All registered in connection
    @test length(client.active_streams) == 3

    # Collect all outgoing frames
    all_bytes = UInt8[]
    for s in streams
        append!(all_bytes, AwsHTTP.h2_stream_get_outgoing_frames!(s))
    end

    # Server decodes all 3 HEADERS frames
    err, frames = AwsHTTP.h2_connection_decode!(server, all_bytes)
    @test !AwsHTTP.h2err_failed(err)
    @test length(frames) == 3
    @test all(f -> f.frame_type == AwsHTTP.H2FrameType.HEADERS, frames)
    @test Set([f.stream_id for f in frames]) == Set([UInt32(1), UInt32(3), UInt32(5)])
end

# ─── Phase 18: Test infrastructure ───

# ─── 18.1: H2 fake peer + decode tester ───

"""
    H2FakePeer - A mock HTTP/2 peer that encodes/decodes frames
    for testing. Wraps an H2Connection and manages preface exchange.
"""
mutable struct H2FakePeer
    conn::AwsHTTP.H2Connection
    received_frames::Vector{AwsHTTP.H2DecodedFrame}
end

function h2_fake_peer_new(; is_client::Bool=false)
    conn = AwsHTTP.h2_connection_new(is_client=is_client)
    return H2FakePeer(conn, AwsHTTP.H2DecodedFrame[])
end

function h2_fake_peer_get_preface(peer::H2FakePeer)::Vector{UInt8}
    _, bytes = AwsHTTP.h2_connection_get_preface(peer.conn)
    return bytes
end

function h2_fake_peer_receive!(peer::H2FakePeer, data::AbstractVector{UInt8})::Bool
    err, frames = AwsHTTP.h2_connection_decode!(peer.conn, data)
    append!(peer.received_frames, frames)
    return !AwsHTTP.h2err_failed(err)
end

function h2_fake_peer_get_outgoing!(peer::H2FakePeer)::Vector{UInt8}
    return AwsHTTP.h2_connection_get_outgoing_frames!(peer.conn)
end

function h2_fake_peer_send_preface!(peer::H2FakePeer, other::H2FakePeer)
    preface = h2_fake_peer_get_preface(peer)
    h2_fake_peer_receive!(other, preface)
end

function h2_fake_peer_exchange_prefaces!(client::H2FakePeer, server::H2FakePeer)
    h2_fake_peer_send_preface!(client, server)
    h2_fake_peer_send_preface!(server, client)
    # Exchange SETTINGS ACKs
    server_ack = h2_fake_peer_get_outgoing!(server)
    client_ack = h2_fake_peer_get_outgoing!(client)
    h2_fake_peer_receive!(server, client_ack)
    h2_fake_peer_receive!(client, server_ack)
end

function h2_fake_peer_find_frame(peer::H2FakePeer, frame_type::AwsHTTP.H2FrameType.T;
    stream_id::Union{UInt32, Nothing}=nothing)::Union{AwsHTTP.H2DecodedFrame, Nothing}
    for f in peer.received_frames
        if f.frame_type == frame_type
            if stream_id === nothing || f.stream_id == stream_id
                return f
            end
        end
    end
    return nothing
end

function h2_fake_peer_count_frames(peer::H2FakePeer, frame_type::AwsHTTP.H2FrameType.T)::Int
    return count(f -> f.frame_type == frame_type, peer.received_frames)
end

function h2_fake_peer_clear_frames!(peer::H2FakePeer)
    empty!(peer.received_frames)
end

"""
    TestInputStream - Configurable input stream for testing.
    Supports throttling (max bytes per read) and error injection.
"""
mutable struct TestInputStream <: IO
    data::Vector{UInt8}
    pos::Int
    max_bytes_per_read::Int
    is_broken::Bool
    read_count::Int
end

function test_input_stream_new(data::Union{String, Vector{UInt8}}; max_bytes_per_read::Int=0)
    d = data isa String ? Vector{UInt8}(data) : copy(data)
    return TestInputStream(d, 1, max_bytes_per_read, false, 0)
end

function Base.readbytes!(s::TestInputStream, buf::Vector{UInt8}, nb::Int)
    s.is_broken && error("TestInputStream: broken")
    s.read_count += 1
    remaining = length(s.data) - s.pos + 1
    remaining <= 0 && return 0
    to_read = min(nb, remaining)
    if s.max_bytes_per_read > 0
        to_read = min(to_read, s.max_bytes_per_read)
    end
    copyto!(buf, 1, s.data, s.pos, to_read)
    s.pos += to_read
    return to_read
end

Base.eof(s::TestInputStream) = s.pos > length(s.data)

# ─── 18.2: Client stream tester ───

"""
    ClientStreamTester - Captures all stream callbacks for easy assertion.
    Works with both H1 and H2 streams.
"""
mutable struct ClientStreamTester
    response_status::Int
    response_headers::Vector{HttpHeader}
    response_body::Vector{UInt8}
    complete_error_code::Int
    is_complete::Bool
    header_block_done_count::Int
end

function client_stream_tester_new()
    return ClientStreamTester(
        -1,
        HttpHeader[],
        UInt8[],
        -999,
        false,
        0,
    )
end

function client_stream_tester_make_request_options(tester::ClientStreamTester, request::AwsHTTP.HttpMessage)
    return AwsHTTP.HttpMakeRequestOptions(
        request=request,
        user_data=tester,
        on_response_headers=(stream, block, hdrs, ud) -> begin
            append!(ud.response_headers, hdrs)
            return Reseau.OP_SUCCESS
        end,
        on_response_header_block_done=(stream, block, ud) -> begin
            ud.header_block_done_count += 1
            return Reseau.OP_SUCCESS
        end,
        on_response_body=(stream, data, ud) -> begin
            append!(ud.response_body, data)
            return Reseau.OP_SUCCESS
        end,
        on_complete=(stream, ec, ud) -> begin
            ud.complete_error_code = ec
            ud.is_complete = true
            if applicable(AwsHTTP.http_stream_get_incoming_response_status, stream)
                ud.response_status = AwsHTTP.http_stream_get_incoming_response_status(stream)
            elseif applicable(AwsHTTP.h2_stream_get_incoming_response_status, stream)
                ud.response_status = AwsHTTP.h2_stream_get_incoming_response_status(stream)
            end
            nothing
        end,
    )
end

function client_stream_tester_get_header(tester::ClientStreamTester, name::String)::Union{String, Nothing}
    for h in tester.response_headers
        if lowercase(h.name) == lowercase(name)
            return h.value
        end
    end
    return nothing
end

# ─── 18.3: Proxy tester ───

"""
    ProxyTester - Test harness for proxy scenarios.
    Configures proxy options and simulates proxy behavior.
"""
mutable struct ProxyTester
    options::AwsHTTP.HttpProxyOptions
    strategy::Union{AwsHTTP.HttpProxyStrategy, Nothing}
    negotiator::Union{AwsHTTP.HttpProxyNegotiator, Nothing}
    connect_response_status::Int
    connect_request_received::Bool
    connect_request_host::String
    connect_request_port::UInt32
end

function proxy_tester_new(; proxy_host::String="proxy.example.com", proxy_port::UInt32=UInt32(8080),
    connection_type::AwsHTTP.HttpProxyConnectionType.T=AwsHTTP.HttpProxyConnectionType.HTTP_FORWARD,
    auth_type::AwsHTTP.HttpProxyAuthenticationType.T=AwsHTTP.HttpProxyAuthenticationType.NONE,
    auth_username::String="", auth_password::String="")

    options = AwsHTTP.HttpProxyOptions(
        connection_type=connection_type,
        host=proxy_host,
        port=proxy_port,
        auth_type=auth_type,
        auth_username=auth_username,
        auth_password=auth_password,
    )
    return ProxyTester(options, nothing, nothing, 0, false, "", UInt32(0))
end

function proxy_tester_create_strategy!(tester::ProxyTester)
    opts = tester.options
    if opts.auth_type == AwsHTTP.HttpProxyAuthenticationType.BASIC
        tester.strategy = AwsHTTP.http_proxy_strategy_new_basic_auth(
            AwsHTTP.HttpProxyStrategyBasicAuthOptions(
                opts.connection_type, opts.auth_username, opts.auth_password))
    else
        if opts.connection_type == AwsHTTP.HttpProxyConnectionType.HTTP_FORWARD
            tester.strategy = AwsHTTP.http_proxy_strategy_new_forwarding_identity()
        else
            tester.strategy = AwsHTTP.http_proxy_strategy_new_tunneling_one_time_identity()
        end
    end
end

function proxy_tester_create_negotiator!(tester::ProxyTester)
    if tester.strategy === nothing
        proxy_tester_create_strategy!(tester)
    end
    tester.negotiator = AwsHTTP.http_proxy_strategy_create_negotiator(
        tester.strategy)
end

function proxy_tester_simulate_connect!(tester::ProxyTester, target_host::String, target_port::UInt32)
    tester.connect_request_received = true
    tester.connect_request_host = target_host
    tester.connect_request_port = target_port
    tester.connect_response_status = 200
end

# ─── Phase 18 Tests ───

@testset "H2 fake peer - preface exchange" begin
    client = h2_fake_peer_new(is_client=true)
    server = h2_fake_peer_new(is_client=false)
    h2_fake_peer_exchange_prefaces!(client, server)

    @test client.conn.connection_preface_sent
    @test server.conn.connection_preface_sent
end

@testset "H2 fake peer - send and receive request" begin
    client = h2_fake_peer_new(is_client=true)
    server = h2_fake_peer_new(is_client=false)
    h2_fake_peer_exchange_prefaces!(client, server)
    h2_fake_peer_clear_frames!(server)

    # Client sends request
    req = AwsHTTP.http2_message_new_request()
    hdrs = AwsHTTP.http_message_get_headers(req)
    AwsHTTP.http_headers_add(hdrs, ":method", "GET")
    AwsHTTP.http_headers_add(hdrs, ":scheme", "https")
    AwsHTTP.http_headers_add(hdrs, ":path", "/test")
    AwsHTTP.http_headers_add(hdrs, ":authority", "example.com")

    stream = AwsHTTP.h2_stream_new_request(client.conn, AwsHTTP.HttpMakeRequestOptions(request=req))
    AwsHTTP.h2_stream_activate!(stream, client.conn)
    frames = AwsHTTP.h2_stream_get_outgoing_frames!(stream)
    h2_fake_peer_receive!(server, frames)

    # Verify server received HEADERS
    h = h2_fake_peer_find_frame(server, AwsHTTP.H2FrameType.HEADERS)
    @test h !== nothing
    @test h.stream_id == UInt32(1)
    @test h2_fake_peer_count_frames(server, AwsHTTP.H2FrameType.HEADERS) == 1
end

@testset "H2 fake peer - frame searching" begin
    client = h2_fake_peer_new(is_client=true)
    server = h2_fake_peer_new(is_client=false)
    h2_fake_peer_exchange_prefaces!(client, server)
    h2_fake_peer_clear_frames!(server)

    # Send 3 requests to generate 3 HEADERS frames
    for i in 1:3
        req = AwsHTTP.http2_message_new_request()
        h = AwsHTTP.http_message_get_headers(req)
        AwsHTTP.http_headers_add(h, ":method", "GET")
        AwsHTTP.http_headers_add(h, ":scheme", "https")
        AwsHTTP.http_headers_add(h, ":path", "/path$i")
        AwsHTTP.http_headers_add(h, ":authority", "example.com")
        s = AwsHTTP.h2_stream_new_request(client.conn, AwsHTTP.HttpMakeRequestOptions(request=req))
        AwsHTTP.h2_stream_activate!(s, client.conn)
        frames = AwsHTTP.h2_stream_get_outgoing_frames!(s)
        h2_fake_peer_receive!(server, frames)
    end

    @test h2_fake_peer_count_frames(server, AwsHTTP.H2FrameType.HEADERS) == 3
    @test h2_fake_peer_find_frame(server, AwsHTTP.H2FrameType.HEADERS; stream_id=UInt32(3)) !== nothing
    @test h2_fake_peer_find_frame(server, AwsHTTP.H2FrameType.HEADERS; stream_id=UInt32(5)) !== nothing
    @test h2_fake_peer_find_frame(server, AwsHTTP.H2FrameType.HEADERS; stream_id=UInt32(99)) === nothing
end

@testset "TestInputStream - basic read" begin
    s = test_input_stream_new("Hello, World!")
    buf = Vector{UInt8}(undef, 100)
    n = readbytes!(s, buf, 100)
    @test n == 13
    @test String(buf[1:n]) == "Hello, World!"
    @test eof(s)
end

@testset "TestInputStream - throttled read" begin
    s = test_input_stream_new("Hello, World!"; max_bytes_per_read=5)
    result = UInt8[]
    while !eof(s)
        buf = Vector{UInt8}(undef, 100)
        n = readbytes!(s, buf, 100)
        n > 0 && append!(result, buf[1:n])
        @test n <= 5  # never reads more than max
    end
    @test String(result) == "Hello, World!"
    @test s.read_count > 1  # had to read multiple times
end

@testset "TestInputStream - broken stream" begin
    s = test_input_stream_new("data")
    s.is_broken = true
    buf = Vector{UInt8}(undef, 10)
    @test_throws ErrorException readbytes!(s, buf, 10)
end

@testset "ClientStreamTester - H1 round-trip" begin
    tester = client_stream_tester_new()

    # Client sends request using the tester
    req = make_h1_request("GET", "/api/test", ["Host" => "example.com"])
    client_conn = AwsHTTP.h1_connection_new_client()
    opts = client_stream_tester_make_request_options(tester, req)
    stream = AwsHTTP.http_connection_make_request(client_conn, opts)
    @test stream !== nothing
    AwsHTTP.h1_stream_activate!(stream)

    # Encode request
    request_bytes = UInt8[]
    while true
        status, chunk = AwsHTTP.h1_connection_encode_outgoing!(client_conn)
        isempty(chunk) && break
        append!(request_bytes, chunk)
    end

    # Server processes and responds
    server_conn = AwsHTTP.h1_connection_new_server()
    server_stream = AwsHTTP.h1_stream_new_request_handler(AwsHTTP.HttpRequestHandlerOptions(
        server_conn, nothing, nothing, nothing, nothing, nothing, nothing, nothing))
    AwsHTTP.h1_stream_activate!(server_stream)
    AwsHTTP.h1_connection_process_read_data!(server_conn, request_bytes)

    resp = make_h1_response(200, ["Content-Type" => "application/json",
        "Content-Length" => "15"]; body="{\"result\":\"ok\"}")
    enc = AwsHTTP.H1EncoderMessage()
    AwsHTTP.h1_encoder_message_init_from_response!(enc, resp)
    server_stream.encoder_message = enc
    response_bytes = UInt8[]
    while true
        s, chunk = AwsHTTP.h1_connection_encode_outgoing!(server_conn)
        isempty(chunk) && break
        append!(response_bytes, chunk)
    end

    # Client processes response
    AwsHTTP.h1_connection_process_read_data!(client_conn, response_bytes)

    # Verify via tester
    @test tester.is_complete
    @test tester.complete_error_code == 0
    @test tester.response_status == 200
    @test client_stream_tester_get_header(tester, "Content-Type") == "application/json"
    @test String(tester.response_body) == "{\"result\":\"ok\"}"

    AwsHTTP.h1_connection_destroy!(client_conn)
    AwsHTTP.h1_connection_destroy!(server_conn)
end

@testset "http_connection_new_channel_handler - H1 client" begin
    handler = AwsHTTP.http_connection_new_channel_handler(
        is_server = false,
        version = AwsHTTP.HttpVersion.HTTP_1_1,
    )
    @test handler isa AwsHTTP.H1Connection
    @test AwsHTTP.http_connection_is_client(handler)
    @test AwsHTTP.http_connection_is_open(handler)
    @test handler.slot === nothing
    AwsHTTP.h1_connection_destroy!(handler)
end

@testset "http_connection_new_channel_handler - H1 server" begin
    handler = AwsHTTP.http_connection_new_channel_handler(
        is_server = true,
        version = AwsHTTP.HttpVersion.HTTP_1_1,
    )
    @test handler isa AwsHTTP.H1Connection
    @test !AwsHTTP.http_connection_is_client(handler)
    AwsHTTP.h1_connection_destroy!(handler)
end

@testset "http_connection_new_channel_handler - H2 client" begin
    handler = AwsHTTP.http_connection_new_channel_handler(
        is_server = false,
        version = AwsHTTP.HttpVersion.HTTP_2,
    )
    @test handler isa AwsHTTP.H2Connection
    @test handler.is_client
    @test AwsHTTP.http_connection_is_open(handler)
end

@testset "http_connection_new_channel_handler - H2 server" begin
    handler = AwsHTTP.http_connection_new_channel_handler(
        is_server = true,
        version = AwsHTTP.HttpVersion.HTTP_2,
    )
    @test handler isa AwsHTTP.H2Connection
    @test !handler.is_client
end

@testset "http_connection_new_channel_handler - unknown version" begin
    handler = AwsHTTP.http_connection_new_channel_handler(
        is_server = false,
        version = AwsHTTP.HttpVersion.UNKNOWN,
    )
    @test handler === nothing
end

@testset "http_connection_get_channel - without slot" begin
    h1 = AwsHTTP.h1_connection_new_client()
    @test AwsHTTP.http_connection_get_channel(h1) === nothing

    h2 = AwsHTTP.h2_connection_new()
    @test AwsHTTP.http_connection_get_channel(h2) === nothing
    AwsHTTP.h1_connection_destroy!(h1)
end

@testset "ALPN map - default map for http_client_connect" begin
    # Default ALPN map correctly maps protocols
    map = AwsHTTP.http_alpn_map_init()
    @test AwsHTTP.http_alpn_map_get(map, "h2") == AwsHTTP.HttpVersion.HTTP_2
    @test AwsHTTP.http_alpn_map_get(map, "http/1.1") == AwsHTTP.HttpVersion.HTTP_1_1
    @test AwsHTTP.http_alpn_map_get(map, "unknown") == AwsHTTP.HttpVersion.UNKNOWN

    # Copy preserves mappings
    map2 = AwsHTTP.http_alpn_map_init_copy(map)
    @test AwsHTTP.http_alpn_map_get(map2, "h2") == AwsHTTP.HttpVersion.HTTP_2

    # Custom ALPN map can override
    AwsHTTP.http_alpn_map_add!(map2, "h3", AwsHTTP.HttpVersion.HTTP_2)  # hypothetical
    @test AwsHTTP.http_alpn_map_get(map2, "h3") == AwsHTTP.HttpVersion.HTTP_2
    @test AwsHTTP.http_alpn_map_get(map, "h3") == AwsHTTP.HttpVersion.UNKNOWN  # original unchanged
end

@testset "HttpMakeRequestOptions - H2-specific fields" begin
    req = AwsHTTP.http_message_new_request()
    AwsHTTP.http_message_set_request_method(req, "GET")
    AwsHTTP.http_message_set_request_path(req, "/")

    # Default values
    opts = AwsHTTP.HttpMakeRequestOptions(request=req)
    @test opts.http2_use_manual_data_writes == false
    @test opts.http2_priority === nothing
    @test opts.http2_headers_pad_length == UInt32(0)
    @test opts.h2c_upgrade == false
    @test opts.on_h2c_upgrade === nothing

    # Custom values
    opts2 = AwsHTTP.HttpMakeRequestOptions(
        request = req,
        http2_use_manual_data_writes = true,
        http2_priority = :custom_priority,
        http2_headers_pad_length = UInt32(16),
        h2c_upgrade = true,
        on_h2c_upgrade = (s, e, u) -> nothing,
    )
    @test opts2.http2_use_manual_data_writes == true
    @test opts2.http2_priority === :custom_priority
    @test opts2.http2_headers_pad_length == UInt32(16)
    @test opts2.h2c_upgrade == true
    @test opts2.on_h2c_upgrade !== nothing
end

@testset "byte_buffer_as_vector and byte_buffer_as_string" begin
    # Non-empty buffer
    buf = Reseau.ByteBuffer(10)
    for (i, b) in enumerate(codeunits("Hello"))
        buf.mem[i] = b
    end
    buf = Reseau.ByteBuffer(buf.mem, 5)

    vec = Reseau.byte_buffer_as_vector(buf)
    @test vec == UInt8[0x48, 0x65, 0x6c, 0x6c, 0x6f]
    @test length(vec) == 5

    str = Reseau.byte_buffer_as_string(buf)
    @test str == "Hello"

    # Empty buffer
    empty_buf = Reseau.ByteBuffer(0)
    @test Reseau.byte_buffer_as_vector(empty_buf) == UInt8[]
    @test Reseau.byte_buffer_as_string(empty_buf) == ""

    # Buffer with partial capacity used
    big_buf = Reseau.ByteBuffer(100)
    big_buf.mem[1] = UInt8('A')
    big_buf.mem[2] = UInt8('B')
    big_buf = Reseau.ByteBuffer(big_buf.mem, 2)
    @test Reseau.byte_buffer_as_vector(big_buf) == UInt8[0x41, 0x42]
    @test Reseau.byte_buffer_as_string(big_buf) == "AB"
end
