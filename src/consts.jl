# parsing state codes
@enum(ParsingStateCode
    ,es_dead=1
    ,es_start_req_or_res
    ,es_res_or_resp_H
    ,es_res_first_http_major
    ,es_res_http_major
    ,es_res_first_http_minor
    ,es_res_http_minor
    ,es_res_first_status_code
    ,es_res_status_code
    ,es_res_status_start
    ,es_res_status
    ,es_res_line_almost_done
    ,es_start_req
    ,es_req_method
    ,es_req_spaces_before_target
    ,es_req_target
    ,es_req_target_wildcard
    ,es_req_schema
    ,es_req_schema_slash
    ,es_req_schema_slash_slash
    ,es_req_server_start
    ,es_req_server
    ,es_req_server_with_at
    ,es_req_path
    ,es_req_query_string_start
    ,es_req_query_string
    ,es_req_fragment_start
    ,es_req_fragment
    ,es_req_http_start
    ,es_req_http_H
    ,es_req_http_HT
    ,es_req_http_HTT
    ,es_req_http_HTTP
    ,es_req_first_http_major
    ,es_req_http_major
    ,es_req_first_http_minor
    ,es_req_http_minor
    ,es_req_line_almost_done
    ,es_trailer_start
    ,es_header_field_start
    ,es_header_field
    ,es_header_value_discard_ws
    ,es_header_value_discard_ws_almost_done
    ,es_header_value_discard_lws
    ,es_header_value_start
    ,es_header_value
    ,es_header_value_lws
    ,es_header_almost_done
    ,es_headers_almost_done
    ,es_headers_done
    ,es_body_start
    ,es_chunk_size_start
    ,es_chunk_size
    ,es_chunk_parameters
    ,es_chunk_size_almost_done
    ,es_chunk_data
    ,es_chunk_data_almost_done
    ,es_chunk_data_done
    ,es_body_identity
    ,es_body_identity_eof
    ,es_message_done
)
for i in instances(ParsingStateCode)
    @eval const $(Symbol(string(i)[2:end])) = UInt8($i)
end


const CR = '\r'
const bCR = UInt8('\r')
const LF = '\n'
const bLF = UInt8('\n')
const CRLF = "\r\n"
