module AwsHTTP

using EnumX
import Reseau
import Reseau: EventLoops, Sockets

# Re-export error infrastructure from Reseau that we depend on
using Reseau: ERROR_ENUM_BEGIN_RANGE, ERROR_ENUM_END_RANGE,
             LOG_SUBJECT_BEGIN_RANGE, LOG_SUBJECT_END_RANGE,
             LogSubject,
             OP_SUCCESS, OP_ERR, raise_error,
             ERROR_INVALID_ARGUMENT,
             ERROR_INVALID_STATE, ERROR_UNIMPLEMENTED

const ERROR_INVALID_INDEX = ERROR_INVALID_ARGUMENT

# --- core ---
include("http.jl")

# --- request/response ---
include("request_response.jl")

# --- callback wrappers ---
include("callables.jl")

# --- HTTP/1.1 encoder ---
include("h1_encoder.jl")

# --- HTTP connection (base types and API) ---
include("connection.jl")

# --- HTTP/1.1 decoder ---
include("h1_decoder.jl")

# --- HTTP/1.1 stream ---
include("h1_stream.jl")

# --- HTTP/1.1 connection (channel handler) ---
include("h1_connection.jl")

# --- HPACK Huffman coding ---
include("hpack_huffman.jl")

# --- HPACK header compression ---
include("hpack.jl")

# --- HTTP/2 frames ---
include("h2_frames.jl")

# --- HTTP/2 stream ---
include("h2_stream.jl")

# --- HTTP/2 connection ---
include("h2_connection.jl")

# --- Client bootstrap (depends on H1Connection, H2Connection) ---
include("client_bootstrap.jl")

# --- HTTP server ---
include("server.jl")

# --- Connection manager ---
include("connection_manager.jl")

# --- HTTP/2 stream manager ---
include("h2_stream_manager.jl")

# --- String utilities + random access set ---
include("strutil.jl")

# --- Connection monitor + statistics ---
include("connection_monitor.jl")

# --- Proxy support ---
include("proxy.jl")

# --- WebSocket ---
include("websocket.jl")

end # module AwsHTTP
