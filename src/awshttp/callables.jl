# HTTP callback wrappers - concrete, type-erased callable storage.

@inline function _http_callable_object_ref(callable::F) where {F}
    objref = Base.cconvert(Ref{F}, callable)
    objptr = Ptr{Cvoid}(Base.unsafe_convert(Ref{F}, objref))
    return objptr, objref
end

struct _StreamHeadersCallbackWrapper <: Function end

@inline function (::_StreamHeadersCallbackWrapper)(f::F, stream, block_type, headers)::Int where {F}
    return Int(f(stream, block_type, headers))
end

@generated function _stream_headers_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_StreamHeadersCallbackWrapper()), Int, (Ref{$F}, Any, Any, Any))
    end
end

struct StreamHeadersCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function StreamHeadersCallback(callable::F) where {F}
    ptr = _stream_headers_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return StreamHeadersCallback(ptr, objptr, objref)
end

@inline _stream_headers_callback(cb::StreamHeadersCallback) = cb
@inline _stream_headers_callback(::Nothing) = nothing
@inline _stream_headers_callback(cb) = StreamHeadersCallback(cb)

@inline function (f::StreamHeadersCallback)(stream, block_type, headers)::Int
    return ccall(f.ptr, Int, (Ptr{Cvoid}, Any, Any, Any), f.objptr, stream, block_type, headers)
end

struct _StreamHeaderBlockDoneCallbackWrapper <: Function end

@inline function (::_StreamHeaderBlockDoneCallbackWrapper)(f::F, stream, block_type)::Int where {F}
    return Int(f(stream, block_type))
end

@generated function _stream_header_block_done_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_StreamHeaderBlockDoneCallbackWrapper()), Int, (Ref{$F}, Any, Any))
    end
end

struct StreamHeaderBlockDoneCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function StreamHeaderBlockDoneCallback(callable::F) where {F}
    ptr = _stream_header_block_done_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return StreamHeaderBlockDoneCallback(ptr, objptr, objref)
end

@inline _stream_header_block_done_callback(cb::StreamHeaderBlockDoneCallback) = cb
@inline _stream_header_block_done_callback(::Nothing) = nothing
@inline _stream_header_block_done_callback(cb) = StreamHeaderBlockDoneCallback(cb)

@inline function (f::StreamHeaderBlockDoneCallback)(stream, block_type)::Int
    return ccall(f.ptr, Int, (Ptr{Cvoid}, Any, Any), f.objptr, stream, block_type)
end

struct _StreamBodyCallbackWrapper <: Function end

@inline function (::_StreamBodyCallbackWrapper)(f::F, stream, data)::Int where {F}
    return Int(f(stream, data))
end

@generated function _stream_body_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_StreamBodyCallbackWrapper()), Int, (Ref{$F}, Any, Any))
    end
end

struct StreamBodyCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function StreamBodyCallback(callable::F) where {F}
    ptr = _stream_body_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return StreamBodyCallback(ptr, objptr, objref)
end

@inline _stream_body_callback(cb::StreamBodyCallback) = cb
@inline _stream_body_callback(::Nothing) = nothing
@inline _stream_body_callback(cb) = StreamBodyCallback(cb)

@inline function (f::StreamBodyCallback)(stream, data)::Int
    return ccall(f.ptr, Int, (Ptr{Cvoid}, Any, Any), f.objptr, stream, data)
end

struct _StreamRequestDoneCallbackWrapper <: Function end

@inline function (::_StreamRequestDoneCallbackWrapper)(f::F, stream)::Nothing where {F}
    f(stream)
    return nothing
end

@generated function _stream_request_done_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_StreamRequestDoneCallbackWrapper()), Cvoid, (Ref{$F}, Any))
    end
end

struct StreamRequestDoneCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function StreamRequestDoneCallback(callable::F) where {F}
    ptr = _stream_request_done_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return StreamRequestDoneCallback(ptr, objptr, objref)
end

@inline _stream_request_done_callback(cb::StreamRequestDoneCallback) = cb
@inline _stream_request_done_callback(::Nothing) = nothing
@inline _stream_request_done_callback(cb) = StreamRequestDoneCallback(cb)

@inline function (f::StreamRequestDoneCallback)(stream)::Nothing
    ccall(f.ptr, Cvoid, (Ptr{Cvoid}, Any), f.objptr, stream)
    return nothing
end

struct _StreamMetricsCallbackWrapper <: Function end

@inline function (::_StreamMetricsCallbackWrapper)(f::F, stream, metrics)::Nothing where {F}
    f(stream, metrics)
    return nothing
end

@generated function _stream_metrics_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_StreamMetricsCallbackWrapper()), Cvoid, (Ref{$F}, Any, Any))
    end
end

struct StreamMetricsCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function StreamMetricsCallback(callable::F) where {F}
    ptr = _stream_metrics_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return StreamMetricsCallback(ptr, objptr, objref)
end

@inline _stream_metrics_callback(cb::StreamMetricsCallback) = cb
@inline _stream_metrics_callback(::Nothing) = nothing
@inline _stream_metrics_callback(cb) = StreamMetricsCallback(cb)

@inline function (f::StreamMetricsCallback)(stream, metrics)::Nothing
    ccall(f.ptr, Cvoid, (Ptr{Cvoid}, Any, Any), f.objptr, stream, metrics)
    return nothing
end

struct _StreamCompleteCallbackWrapper <: Function end

@inline function (::_StreamCompleteCallbackWrapper)(f::F, stream, error_code::Int)::Nothing where {F}
    f(stream, error_code)
    return nothing
end

@generated function _stream_complete_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_StreamCompleteCallbackWrapper()), Cvoid, (Ref{$F}, Any, Int))
    end
end

struct StreamCompleteCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function StreamCompleteCallback(callable::F) where {F}
    ptr = _stream_complete_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return StreamCompleteCallback(ptr, objptr, objref)
end

@inline _stream_complete_callback(cb::StreamCompleteCallback) = cb
@inline _stream_complete_callback(::Nothing) = nothing
@inline _stream_complete_callback(cb) = StreamCompleteCallback(cb)

@inline function (f::StreamCompleteCallback)(stream, error_code::Int)::Nothing
    ccall(f.ptr, Cvoid, (Ptr{Cvoid}, Any, Int), f.objptr, stream, error_code)
    return nothing
end

struct _StreamDestroyCallbackWrapper <: Function end

@inline function (::_StreamDestroyCallbackWrapper)(f::F, stream)::Nothing where {F}
    f(stream)
    return nothing
end

@generated function _stream_destroy_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_StreamDestroyCallbackWrapper()), Cvoid, (Ref{$F}, Any))
    end
end

struct StreamDestroyCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function StreamDestroyCallback(callable::F) where {F}
    ptr = _stream_destroy_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return StreamDestroyCallback(ptr, objptr, objref)
end

@inline _stream_destroy_callback(cb::StreamDestroyCallback) = cb
@inline _stream_destroy_callback(::Nothing) = nothing
@inline _stream_destroy_callback(cb) = StreamDestroyCallback(cb)

@inline function (f::StreamDestroyCallback)(stream)::Nothing
    ccall(f.ptr, Cvoid, (Ptr{Cvoid}, Any), f.objptr, stream)
    return nothing
end

struct _StreamPushPromiseCallbackWrapper <: Function end

@inline function (::_StreamPushPromiseCallbackWrapper)(f::F, stream, promised_stream_id::UInt32, headers)::Nothing where {F}
    f(stream, promised_stream_id, headers)
    return nothing
end

@generated function _stream_push_promise_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_StreamPushPromiseCallbackWrapper()), Cvoid, (Ref{$F}, Any, UInt32, Any))
    end
end

struct StreamPushPromiseCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function StreamPushPromiseCallback(callable::F) where {F}
    ptr = _stream_push_promise_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return StreamPushPromiseCallback(ptr, objptr, objref)
end

@inline _stream_push_promise_callback(cb::StreamPushPromiseCallback) = cb
@inline _stream_push_promise_callback(::Nothing) = nothing
@inline _stream_push_promise_callback(cb) = StreamPushPromiseCallback(cb)

@inline function (f::StreamPushPromiseCallback)(stream, promised_stream_id::UInt32, headers)::Nothing
    ccall(f.ptr, Cvoid, (Ptr{Cvoid}, Any, UInt32, Any), f.objptr, stream, promised_stream_id, headers)
    return nothing
end

struct _ConnectionIncomingRequestCallbackWrapper <: Function end

@inline function (::_ConnectionIncomingRequestCallbackWrapper)(f::F, connection)::Any where {F}
    return f(connection)
end

@generated function _connection_incoming_request_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_ConnectionIncomingRequestCallbackWrapper()), Any, (Ref{$F}, Any))
    end
end

struct ConnectionIncomingRequestCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function ConnectionIncomingRequestCallback(callable::F) where {F}
    ptr = _connection_incoming_request_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return ConnectionIncomingRequestCallback(ptr, objptr, objref)
end

@inline _connection_incoming_request_callback(cb::ConnectionIncomingRequestCallback) = cb
@inline _connection_incoming_request_callback(::Nothing) = nothing
@inline _connection_incoming_request_callback(cb) = ConnectionIncomingRequestCallback(cb)

@inline function (f::ConnectionIncomingRequestCallback)(connection)
    return ccall(f.ptr, Any, (Ptr{Cvoid}, Any), f.objptr, connection)
end

struct _ConnectionH2CUpgradeCallbackWrapper <: Function end

@inline function (::_ConnectionH2CUpgradeCallbackWrapper)(f::F, connection, request_message)::UInt8 where {F}
    return f(connection, request_message) ? UInt8(1) : UInt8(0)
end

@generated function _connection_h2c_upgrade_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_ConnectionH2CUpgradeCallbackWrapper()), UInt8, (Ref{$F}, Any, Any))
    end
end

struct ConnectionH2CUpgradeCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function ConnectionH2CUpgradeCallback(callable::F) where {F}
    ptr = _connection_h2c_upgrade_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return ConnectionH2CUpgradeCallback(ptr, objptr, objref)
end

@inline _connection_h2c_upgrade_callback(cb::ConnectionH2CUpgradeCallback) = cb
@inline _connection_h2c_upgrade_callback(::Nothing) = nothing
@inline _connection_h2c_upgrade_callback(cb) = ConnectionH2CUpgradeCallback(cb)

@inline function (f::ConnectionH2CUpgradeCallback)(connection, request_message)::Bool
    return ccall(f.ptr, UInt8, (Ptr{Cvoid}, Any, Any), f.objptr, connection, request_message) != 0x00
end

struct _ConnectionShutdownCallbackWrapper <: Function end

@inline function (::_ConnectionShutdownCallbackWrapper)(f::F, connection, error_code::Int)::Nothing where {F}
    f(connection, error_code)
    return nothing
end

@generated function _connection_shutdown_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_ConnectionShutdownCallbackWrapper()), Cvoid, (Ref{$F}, Any, Int))
    end
end

struct ConnectionShutdownCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function ConnectionShutdownCallback(callable::F) where {F}
    ptr = _connection_shutdown_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return ConnectionShutdownCallback(ptr, objptr, objref)
end

@inline _connection_shutdown_callback(cb::ConnectionShutdownCallback) = cb
@inline _connection_shutdown_callback(::Nothing) = nothing
@inline _connection_shutdown_callback(cb) = ConnectionShutdownCallback(cb)

@inline function (f::ConnectionShutdownCallback)(connection, error_code::Int)::Nothing
    ccall(f.ptr, Cvoid, (Ptr{Cvoid}, Any, Int), f.objptr, connection, error_code)
    return nothing
end

struct _ConnectionGoawayCallbackWrapper <: Function end

@inline function (::_ConnectionGoawayCallbackWrapper)(f::F, last_stream_id::UInt32, error_code::UInt32, debug_data)::Nothing where {F}
    f(last_stream_id, error_code, debug_data)
    return nothing
end

@generated function _connection_goaway_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_ConnectionGoawayCallbackWrapper()), Cvoid, (Ref{$F}, UInt32, UInt32, Any))
    end
end

struct ConnectionGoawayCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function ConnectionGoawayCallback(callable::F) where {F}
    ptr = _connection_goaway_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return ConnectionGoawayCallback(ptr, objptr, objref)
end

@inline _connection_goaway_callback(cb::ConnectionGoawayCallback) = cb
@inline _connection_goaway_callback(::Nothing) = nothing
@inline _connection_goaway_callback(cb) = ConnectionGoawayCallback(cb)

@inline function (f::ConnectionGoawayCallback)(last_stream_id::UInt32, error_code::UInt32, debug_data)::Nothing
    ccall(f.ptr, Cvoid, (Ptr{Cvoid}, UInt32, UInt32, Any), f.objptr, last_stream_id, error_code, debug_data)
    return nothing
end

struct _ConnectionRemoteSettingsCallbackWrapper <: Function end

@inline function (::_ConnectionRemoteSettingsCallbackWrapper)(f::F, settings)::Nothing where {F}
    f(settings)
    return nothing
end

@generated function _connection_remote_settings_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_ConnectionRemoteSettingsCallbackWrapper()), Cvoid, (Ref{$F}, Any))
    end
end

struct ConnectionRemoteSettingsCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function ConnectionRemoteSettingsCallback(callable::F) where {F}
    ptr = _connection_remote_settings_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return ConnectionRemoteSettingsCallback(ptr, objptr, objref)
end

@inline _connection_remote_settings_callback(cb::ConnectionRemoteSettingsCallback) = cb
@inline _connection_remote_settings_callback(::Nothing) = nothing
@inline _connection_remote_settings_callback(cb) = ConnectionRemoteSettingsCallback(cb)

@inline function (f::ConnectionRemoteSettingsCallback)(settings)::Nothing
    ccall(f.ptr, Cvoid, (Ptr{Cvoid}, Any), f.objptr, settings)
    return nothing
end

struct _H2CUpgradeResultCallbackWrapper <: Function end

@inline function (::_H2CUpgradeResultCallbackWrapper)(f::F, h1_connection, h2_connection, h2_stream, error_code::Int)::Nothing where {F}
    f(h1_connection, h2_connection, h2_stream, error_code)
    return nothing
end

@generated function _h2c_upgrade_result_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_H2CUpgradeResultCallbackWrapper()), Cvoid, (Ref{$F}, Any, Any, Any, Int))
    end
end

struct H2CUpgradeResultCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function H2CUpgradeResultCallback(callable::F) where {F}
    ptr = _h2c_upgrade_result_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return H2CUpgradeResultCallback(ptr, objptr, objref)
end

@inline _h2c_upgrade_result_callback(cb::H2CUpgradeResultCallback) = cb
@inline _h2c_upgrade_result_callback(::Nothing) = nothing
@inline _h2c_upgrade_result_callback(cb) = H2CUpgradeResultCallback(cb)

@inline function (f::H2CUpgradeResultCallback)(h1_connection, h2_connection, h2_stream, error_code::Int)::Nothing
    ccall(f.ptr, Cvoid, (Ptr{Cvoid}, Any, Any, Any, Int), f.objptr, h1_connection, h2_connection, h2_stream, error_code)
    return nothing
end

struct _WebSocketIncomingFrameCallbackWrapper <: Function end

@inline function (::_WebSocketIncomingFrameCallbackWrapper)(f::F, ws, frame_info, payload, error_code::Int)::UInt8 where {F}
    return f(ws, frame_info, payload, error_code) ? UInt8(1) : UInt8(0)
end

@generated function _websocket_incoming_frame_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_WebSocketIncomingFrameCallbackWrapper()), UInt8, (Ref{$F}, Any, Any, Any, Int))
    end
end

struct WebSocketIncomingFrameCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function WebSocketIncomingFrameCallback(callable::F) where {F}
    ptr = _websocket_incoming_frame_callback_fptr(F)
    objptr, objref = _http_callable_object_ref(callable)
    return WebSocketIncomingFrameCallback(ptr, objptr, objref)
end

@inline _websocket_incoming_frame_callback(cb::WebSocketIncomingFrameCallback) = cb
@inline _websocket_incoming_frame_callback(::Nothing) = nothing
@inline _websocket_incoming_frame_callback(cb) = WebSocketIncomingFrameCallback(cb)

@inline function (f::WebSocketIncomingFrameCallback)(ws, frame_info, payload, error_code::Int)::Bool
    return ccall(f.ptr, UInt8, (Ptr{Cvoid}, Any, Any, Any, Int), f.objptr, ws, frame_info, payload, error_code) != 0x00
end
